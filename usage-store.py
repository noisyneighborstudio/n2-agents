#!/usr/bin/env python3
"""Local usage journal and bounded exchange over the authenticated fleet carrier."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
import uuid

MAX_BATCH = 1000
MAX_BYTES = 2 * 1024 * 1024
STATUSES = {'ok', 'restricted', 'no-token', 'stale-token', 'fetch-error', 'rate-limited',
            'no-usage-api', 'shared-login', 'credential-override', 'credential-store-unavailable'}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def fields(value, allowed):
    if not isinstance(value, dict) or set(value) - set(allowed):
        raise ValueError('invalid structured fields')


def finite(value, maximum=None):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and value >= 0 and (maximum is None or value <= maximum))


def validate_data(data):
    fields(data, {'status', 'identity', 'windows', 'restrictions', 'credits', 'source', 'display',
                  'session', 'model', 'recheckAt', 'resetKnown', 'attribution'})
    identity = data.get('identity', {})
    fields(identity, {'status', 'loginHash', 'accountHash', 'organizationHash'})
    if identity.get('status', 'unknown') not in ('unknown', 'login-only', 'verified', 'conflicting', 'unavailable'):
        raise ValueError('invalid identity state')
    for key, value in identity.items():
        if key != 'status' and (not isinstance(value, str) or not re.fullmatch('[a-f0-9]{64}', value)):
            raise ValueError('invalid identity hash')
    if identity.get('status') == 'verified' and not identity.get('accountHash'):
        raise ValueError('verified identity requires account evidence')
    windows = data.get('windows', [])
    restrictions = data.get('restrictions', [])
    if not isinstance(windows, list) or len(windows) > 64 or not isinstance(restrictions, list) or len(restrictions) > 64:
        raise ValueError('invalid limit lists')
    for window in windows:
        fields(window, {'scope', 'durationSeconds', 'usedPercent', 'resetsAt'})
        if window.get('usedPercent') is not None and not finite(window['usedPercent'], 100):
            raise ValueError('invalid usage percentage')
        if window.get('durationSeconds') is not None and not finite(window['durationSeconds']):
            raise ValueError('invalid window duration')
    for restriction in restrictions:
        fields(restriction, {'scope', 'reason', 'resetsAt'})
    credits = data.get('credits', {})
    if not isinstance(credits, dict) or len(credits) > 64:
        raise ValueError('invalid credits')
    for credit in credits.values():
        fields(credit, {'hasCredits', 'unlimited', 'balance', 'is_enabled', 'monthly_limit',
                        'used_credits', 'utilization', 'disabled_reason', 'spend_limit_reached'})
    fields(data.get('display', {}), {'shortUsed', 'longUsed', 'shortResets', 'longResets'})
    fields(data.get('attribution', {}), {'inputTokens', 'outputTokens', 'cachedInputTokens', 'totalTokens', 'task'})
    def scalar(value):
        if isinstance(value, (dict, list)):
            raise ValueError('containers are not metadata leaves')
    for key in ('session', 'model', 'source'):
        if data.get(key) is not None and not isinstance(data[key], str):
            raise ValueError('invalid text metadata')
    if data.get('recheckAt') is not None and not finite(data['recheckAt']):
        raise ValueError('invalid recheck time')
    if 'resetKnown' in data and not isinstance(data['resetKnown'], bool):
        raise ValueError('invalid reset evidence')
    for value in identity.values(): scalar(value)
    for item in windows + restrictions:
        for value in item.values(): scalar(value)
        if not isinstance(item.get('scope'), str):
            raise ValueError('invalid limit scope')
        if 'reason' in item and not isinstance(item['reason'], str):
            raise ValueError('invalid rejection reason')
    for item in credits.values():
        for value in item.values(): scalar(value)
    for key, value in data.get('display', {}).items():
        scalar(value)
        if key.endswith('Used') and value not in ('-', None) and not finite(value, 100):
            raise ValueError('invalid display percentage')
    for key, value in data.get('attribution', {}).items():
        if key == 'task':
            if value is not None and not isinstance(value, str):
                raise ValueError('invalid task identity')
        elif value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 0):
            raise ValueError('invalid token count')
    def bounded(value, depth=0):
        if depth > 5:
            raise ValueError('nested data too deep')
        if isinstance(value, dict):
            for key, item in value.items():
                if not isinstance(key, str) or len(key) > 128:
                    raise ValueError('invalid field name')
                bounded(item, depth + 1)
        elif isinstance(value, list):
            for item in value: bounded(item, depth + 1)
        elif isinstance(value, str):
            if len(value) > 512 or any(ord(c) < 32 for c in value):
                raise ValueError('invalid metadata string')
        elif value is not None and not isinstance(value, bool) and not finite(value):
            raise ValueError('invalid metadata value')
    bounded(data)


def validate(event):
    if not isinstance(event, dict) or set(event) != {'id', 'origin', 'at', 'kind', 'provider', 'profile', 'data'}:
        raise ValueError('invalid event fields')
    if not isinstance(event['origin'], str) or len(event['origin']) > 128:
        raise ValueError('invalid origin')
    if not isinstance(event['at'], (int, float)) or isinstance(event['at'], bool) or not math.isfinite(event['at']):
        raise ValueError('invalid timestamp')
    if event['at'] > time.time() + 300 or event['at'] < 0:
        raise ValueError('invalid observation time')
    if event['provider'] not in ('claude', 'codex', 'grok', 'muse', 'cursor', 'opencode'):
        raise ValueError('unknown provider')
    if not isinstance(event['profile'], str) or not re.fullmatch(r'[A-Za-z0-9]+', event['profile']):
        raise ValueError('invalid profile')
    if event['kind'] not in ('measurement', 'quota-rejected', 'execution-succeeded'):
        raise ValueError('unknown event kind')
    if not isinstance(event['data'], dict) or len(canonical(event['data'])) > 16384:
        raise ValueError('invalid event data')
    # Events contain a fixed measurement schema, never raw provider output,
    # transcripts, command arguments or credentials.
    allowed = {'status', 'identity', 'windows', 'restrictions', 'credits', 'source', 'display',
               'session', 'model', 'recheckAt', 'resetKnown', 'attribution'}
    if set(event['data']) - allowed:
        raise ValueError('unknown event data fields')
    validate_data(event['data'])
    if 'status' in event['data'] and event['data']['status'] not in STATUSES:
        raise ValueError('unknown status')
    expected = hashlib.sha256(canonical({k: v for k, v in event.items() if k != 'id'}).encode()).hexdigest()
    if event['id'] != expected:
        raise ValueError('event digest mismatch')
    return event


class Journal:
    def __init__(self, root, origin=None):
        directory = Path(root) / '.usage'
        if directory.is_symlink():
            raise ValueError('usage directory cannot be a symlink')
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(directory, 0o700)
        path = directory / 'events.sqlite'
        if path.is_symlink():
            raise ValueError('usage database cannot be a symlink')
        fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        os.close(fd)
        os.chmod(path, 0o600)
        self.db = sqlite3.connect(path, timeout=10)
        self.db.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, origin TEXT NOT NULL, at REAL NOT NULL, provider TEXT NOT NULL, profile TEXT NOT NULL, body TEXT NOT NULL)')
        self.db.execute('CREATE INDEX IF NOT EXISTS events_binding ON events(origin, provider, profile, at)')
        self.db.execute('INSERT OR IGNORE INTO settings VALUES (?, ?)', ('local-origin', 'local:' + str(uuid.uuid4())))
        self.db.commit()
        self.origin = origin or self.db.execute('SELECT value FROM settings WHERE key=?', ('local-origin',)).fetchone()[0]

    def append(self, provider, profile, kind, data, at=None):
        event = {'origin': self.origin, 'at': time.time() if at is None else at,
                 'kind': kind, 'provider': provider, 'profile': profile, 'data': data}
        event['id'] = hashlib.sha256(canonical(event).encode()).hexdigest()
        self.import_events([event], self.origin)
        return event

    def import_events(self, events, source):
        if not isinstance(events, list) or len(events) > MAX_BATCH:
            raise ValueError('invalid event batch')
        for event in events:
            validate(event)
            if event['origin'] != source:
                raise ValueError('event origin does not match authenticated peer')
        with self.db:
            for event in events:
                self.db.execute('INSERT OR IGNORE INTO events VALUES (?, ?, ?, ?, ?, ?)',
                                (event['id'], source, event['at'], event['provider'], event['profile'], canonical(event)))
            # Bounded diagnostic history; current quota state must not be inferred
            # from absence of an old event after retention.
            self.db.execute('DELETE FROM events WHERE at < ?', (time.time() - 30 * 86400,))

    def events(self, own=False, limit=MAX_BATCH):
        if own:
            rows = self.db.execute('SELECT body FROM events WHERE origin=? ORDER BY at DESC, id DESC LIMIT ?', (self.origin, limit))
        else:
            rows = self.db.execute('SELECT body FROM events ORDER BY at DESC, id DESC LIMIT ?', (limit,))
        result, size = [], 3  # array delimiters and terminating newline
        for row in rows:
            encoded = canonical(json.loads(row[0]))
            added = len(encoded.encode('utf-8')) + (1 if result else 0)
            if size + added > MAX_BYTES:
                break
            result.append(json.loads(row[0]))
            size += added
        return result

    def latest(self, provider, profile):
        row = self.db.execute('SELECT body FROM events WHERE origin=? AND provider=? AND profile=? ORDER BY at DESC, id DESC LIMIT 1',
                              (self.origin, provider, profile)).fetchone()
        return json.loads(row[0]) if row else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--origin')
    parser.add_argument('verb', choices=['history', 'export', 'import', 'record'])
    parser.add_argument('--source')
    parser.add_argument('--provider')
    parser.add_argument('--profile')
    parser.add_argument('--kind', default='measurement')
    parser.add_argument('--data', help='sanitized metadata JSON; otherwise read stdin')
    args = parser.parse_args()
    journal = Journal(args.root, args.origin)
    if args.verb in ('history', 'export'):
        print(canonical(journal.events(own=args.verb == 'export')))
        return
    raw = args.data if args.data is not None else sys.stdin.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError('event batch too large')
    data = json.loads(raw)
    if args.verb == 'import':
        if not args.source:
            raise ValueError('authenticated source required')
        journal.import_events(data, args.source)
    else:
        print(canonical(journal.append(args.provider, args.profile, args.kind, data)))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, sqlite3.Error) as error:
        # Input may be hostile. Do not echo it or database contents.
        print('agents: usage journal operation failed (' + type(error).__name__ + ')', file=sys.stderr)
        sys.exit(1)
