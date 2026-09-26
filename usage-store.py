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
            'no-usage-api', 'shared-login', 'credential-override', 'credential-store-unavailable', 'execution-failed'}


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
                  'session', 'model', 'requestedModel', 'usageScope', 'modelUsage', 'startedAt', 'recheckAt', 'resetKnown', 'attribution'})
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
    fields(data.get('attribution', {}), {'inputTokens', 'outputTokens', 'cachedInputTokens', 'cacheCreationInputTokens', 'uncachedInputTokens', 'totalTokens', 'task'})
    def scalar(value):
        if isinstance(value, (dict, list)):
            raise ValueError('containers are not metadata leaves')
    for key in ('session', 'model', 'requestedModel', 'usageScope', 'source'):
        if data.get(key) is not None and not isinstance(data[key], str):
            raise ValueError('invalid text metadata')
    if data.get('startedAt') is not None and not finite(data['startedAt']):
        raise ValueError('invalid invocation start')
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
    model_usage = data.get('modelUsage', {})
    if not isinstance(model_usage, dict) or len(model_usage) > 64:
        raise ValueError('invalid model usage')
    for counts in model_usage.values():
        fields(counts, {'inputTokens', 'outputTokens', 'cachedInputTokens', 'cacheCreationInputTokens', 'uncachedInputTokens', 'totalTokens'})
        for value in counts.values():
            if value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 0):
                raise ValueError('invalid model token count')
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
    if event['kind'] not in ('measurement', 'quota-rejected', 'execution-succeeded', 'execution-failed'):
        raise ValueError('unknown event kind')
    if not isinstance(event['data'], dict) or len(canonical(event['data'])) > 16384:
        raise ValueError('invalid event data')
    # Events contain a fixed measurement schema, never raw provider output,
    # transcripts, command arguments or credentials.
    allowed = {'status', 'identity', 'windows', 'restrictions', 'credits', 'source', 'display',
               'session', 'model', 'requestedModel', 'usageScope', 'modelUsage', 'startedAt', 'recheckAt', 'resetKnown', 'attribution'}
    if set(event['data']) - allowed:
        raise ValueError('unknown event data fields')
    validate_data(event['data'])
    if event['data'].get('startedAt') is not None and event['data']['startedAt'] > event['at']:
        raise ValueError('invocation starts after observation')
    if 'status' in event['data'] and event['data']['status'] not in STATUSES:
        raise ValueError('unknown status')
    required_status = {'quota-rejected': 'restricted', 'execution-succeeded': 'ok'}.get(event['kind'])
    if required_status and event['data'].get('status') != required_status:
        raise ValueError('execution status conflicts with event kind')
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
        self.db.execute('CREATE TABLE IF NOT EXISTS execution_state (binding TEXT NOT NULL, kind TEXT NOT NULL, at REAL NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(binding, kind))')
        self.db.execute('INSERT OR IGNORE INTO settings VALUES (?, ?)', ('local-origin', 'local:' + str(uuid.uuid4())))
        self.local_origin = self.db.execute('SELECT value FROM settings WHERE key=?', ('local-origin',)).fetchone()[0]
        self.origin = origin or self.local_origin
        if not self.db.execute("SELECT 1 FROM settings WHERE key='execution-state-v3'").fetchone():
            previous = self.db.execute('SELECT body FROM execution_state UNION SELECT body FROM events').fetchall()
            self.db.execute('DELETE FROM execution_state')
            for row in previous:
                self._retain_execution(json.loads(row[0]))
            self.db.execute("INSERT INTO settings VALUES ('execution-state-v3', '1')")
        for kind, body in self.db.execute("SELECT kind, body FROM execution_state WHERE kind LIKE 'quota-rejected:%'").fetchall():
            data = json.loads(body)['data']
            if data.get('resetKnown') is True and data.get('recheckAt') is not None and data['recheckAt'] <= time.time():
                self.db.execute('DELETE FROM execution_state WHERE kind=?', (kind,))
        self.db.commit()

    @staticmethod
    def account(data):
        identity = data.get('identity', {})
        return identity.get('accountHash') if identity.get('status') == 'verified' else None

    def execution_binding(self, event):
        data = event['data']
        # Success clears only the issuing machine's matching route/account and
        # model choice. A different peer's clock or model cannot erase evidence.
        model = (['requested', data['requestedModel']] if data.get('requestedModel') else
                 ['reported', data['model']] if data.get('model') else ['default'])
        origin = self.local_origin if event['origin'] == self.origin else event['origin']
        return canonical([origin, event['provider'], event['profile'], Journal.account(data), model])

    def _retain_execution(self, event):
        if event['kind'] not in ('quota-rejected', 'execution-succeeded'):
            return
        key = self.execution_binding(event)
        kind = event['kind']
        evidence_at = event['at']
        if kind == 'execution-succeeded':
            evidence_at = event['data'].get('startedAt')
            if evidence_at is None:
                return
        if kind == 'quota-rejected':
            data = event['data']
            if data.get('resetKnown') is True and data.get('recheckAt') is not None and data['recheckAt'] <= time.time():
                return
            success = self.db.execute("SELECT at FROM execution_state WHERE binding=? AND kind='execution-succeeded'", (key,)).fetchone()
            if success and success[0] > event['at']:
                return
            kind += ':' + event['id']
        self.db.execute('''INSERT INTO execution_state VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(binding, kind) DO UPDATE SET at=excluded.at, id=excluded.id, body=excluded.body
            WHERE excluded.at > execution_state.at OR
                  (excluded.at = execution_state.at AND excluded.id > execution_state.id)''',
            (key, kind, evidence_at, event['id'], canonical(event)))
        if kind == 'execution-succeeded':
            self.db.execute("DELETE FROM execution_state WHERE binding=? AND kind LIKE 'quota-rejected:%' AND at < (SELECT at FROM execution_state WHERE binding=? AND kind='execution-succeeded')", (key, key))

    def active_rejections(self, now=None):
        now = time.time() if now is None else now
        result = []
        for binding, at, body in self.db.execute("SELECT binding, at, body FROM execution_state WHERE kind LIKE 'quota-rejected:%'"):
            event = json.loads(body)
            data = event['data']
            if data.get('resetKnown') is True and data.get('recheckAt') is not None and data['recheckAt'] <= now:
                continue
            success = self.db.execute("SELECT at FROM execution_state WHERE binding=? AND kind='execution-succeeded'", (binding,)).fetchone()
            if success and success[0] > at:
                continue
            result.append(event)
        return sorted(result, key=lambda event: (event['at'], event['id']), reverse=True)

    def effective(self, provider, profile, measurement):
        result = dict(measurement)
        account = self.account(measurement)
        blocks = []
        for event in self.active_rejections():
            if event['provider'] != provider:
                continue
            rejected_account = self.account(event['data'])
            same_account = account is not None and account == rejected_account
            local_route = event['origin'] in (self.origin, self.local_origin) and event['profile'] == profile
            # A verified account change separates routes. With incomplete
            # identity, a local rejection stays attached to the launch binding.
            if same_account or (local_route and (account is None or rejected_account is None)):
                data = event['data']
                blocks.append({'scope': 'execution', 'reason': 'quota-rejected',
                               'resetsAt': data.get('recheckAt') if data.get('resetKnown') else None})
        if blocks:
            reset = max(b['resetsAt'] for b in blocks) if all(b['resetsAt'] is not None for b in blocks) else None
            result['restrictions'] = list(result.get('restrictions', [])) + [{'scope': 'execution', 'reason': 'quota-rejected', 'resetsAt': reset}]
            if result.get('status') in ('ok', 'restricted', 'no-usage-api'):
                result['status'] = 'restricted'
        return result

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
                self._retain_execution(event)
            # Bounded diagnostic history; current quota state must not be inferred
            # from absence of an old event after retention.
            self.db.execute('DELETE FROM events WHERE at < ?', (time.time() - 30 * 86400,))

    def events(self, own=False, limit=MAX_BATCH):
        if own:
            # Recovery tombstones travel with rejections, including after the
            # diagnostic log expires. Reserve the batch for this state first.
            state = [json.loads(row[0]) for row in self.db.execute('SELECT body FROM execution_state ORDER BY at DESC, id DESC')
                     if json.loads(row[0])['origin'] == self.origin]
            if len(state) > limit or len((canonical(state) + '\n').encode()) > MAX_BYTES:
                raise ValueError('execution state requires a larger exchange protocol')
            ids = {event['id'] for event in state}
            history = self.db.execute('SELECT id, body FROM events WHERE origin=? ORDER BY at DESC, id DESC LIMIT ?', (self.origin, limit))
            rows = [(canonical(event),) for event in state] + [(row[1],) for row in history if row[0] not in ids]
            rows = rows[:limit]
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

    def token_summary(self):
        # A task can be observed again during recovery. Use its latest record,
        # rather than counting that invocation twice. Imported replays already
        # deduplicate by event ID. Allowance percentages never enter this sum.
        tasks, groups = set(), {}
        for row in self.db.execute('SELECT body FROM events WHERE at >= ? ORDER BY at DESC, id DESC', (time.time() - 30 * 86400,)):
            event = json.loads(row[0])
            if event['kind'] == 'measurement':
                continue
            data = event['data']
            attribution = data.get('attribution', {})
            task = attribution.get('task') or event['id']
            task_key = (event['origin'], event['provider'], task)
            if task_key in tasks:
                continue
            tasks.add(task_key)
            identity = data.get('identity', {})
            account = identity.get('accountHash') if identity.get('status') == 'verified' else None
            binding = account or (event['origin'], event['profile'])
            model_counts = data.get('modelUsage') or {data.get('model'): attribution}
            for model, counts in model_counts.items():
                key = (event['provider'], binding, model, data.get('usageScope', 'unknown'))
                if key not in groups:
                    groups[key] = {'provider': event['provider'], 'accountHash': account,
                                   'identityStatus': 'verified' if account else 'unverified',
                                   'model': model, 'usageScope': data.get('usageScope', 'unknown'), 'bindings': [], 'tasks': 0,
                                   'knownTokenTasks': 0, 'unknownTokenTasks': 0,
                                   'reportedTotalTokens': 0}
                group = groups[key]
                route = {'origin': event['origin'], 'profile': event['profile']}
                if route not in group['bindings']:
                    group['bindings'].append(route)
                group['tasks'] += 1
                total = counts.get('totalTokens')
                if total is None:
                    group['unknownTokenTasks'] += 1
                else:
                    group['knownTokenTasks'] += 1
                    group['reportedTotalTokens'] += total
        return {'retentionDays': 30, 'uniqueTasks': len(tasks), 'groups': list(groups.values())}

    def latest(self, provider, profile):
        row = self.db.execute('SELECT body FROM events WHERE origin=? AND provider=? AND profile=? ORDER BY at DESC, id DESC LIMIT 1',
                              (self.origin, provider, profile)).fetchone()
        return json.loads(row[0]) if row else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--origin')
    parser.add_argument('verb', choices=['history', 'summary', 'restrictions', 'export', 'import', 'record'])
    parser.add_argument('--source')
    parser.add_argument('--provider')
    parser.add_argument('--profile')
    parser.add_argument('--kind', default='measurement')
    parser.add_argument('--data', help='sanitized metadata JSON; otherwise read stdin')
    args = parser.parse_args()
    journal = Journal(args.root, args.origin)
    if args.verb == 'restrictions':
        print(canonical(journal.active_rejections()))
        return
    if args.verb == 'summary':
        print(canonical(journal.token_summary()))
        return
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
