#!/usr/bin/env python3
"""A Claude slot's long-lived token (`claude setup-token`). Never prints it.

The token lives in the slot's settings.json `env` block, which Claude Code
applies for every launcher (agents run, desktop apps, IDEs, fleet exec) and
prefers over the stored login, so nothing ever refreshes that login.
"""
import json, os, re, sys, tempfile, urllib.request
from datetime import datetime, timezone

KEY = 'CLAUDE_CODE_OAUTH_TOKEN'
PREFIX = 'sk-ant-oat01-'
SHAPE = re.compile(PREFIX + r'[A-Za-z0-9_-]{93}AA')
ANSI = re.compile(r'\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|[@-Z\\-_])')
# Claude Code's own identity; OAuth inference requests are refused without it.
SYSTEM = "You are Claude Code, Anthropic's official CLI for Claude."
PROBE_MODEL = 'claude-haiku-5-5'


def settings_path(cfg):
    return os.path.join(cfg, 'settings.json')


def read(cfg):
    try:
        with open(settings_path(cfg)) as f:
            token = (json.load(f).get('env') or {}).get(KEY)
    except (OSError, ValueError, AttributeError):
        return None
    return token if isinstance(token, str) and SHAPE.fullmatch(token) else None


def write(cfg, token):
    """Set or (token=None) remove the key, keeping every other setting."""
    path = settings_path(cfg)
    try:
        with open(path) as f:
            value = json.load(f)
    except FileNotFoundError:
        value = {}
    env = value.get('env') if isinstance(value.get('env'), dict) else {}
    if token is None:
        if KEY not in env:
            return
        del env[KEY]
    else:
        env[KEY] = token
    if env:
        value['env'] = env
    else:
        value.pop('env', None)
    fd, temporary = tempfile.mkstemp(dir=cfg)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, indent=2)
            f.write('\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def capture(transcript):
    """The last token a `setup-token` terminal transcript shows. The TUI wraps
    it at the terminal width, so whitespace inside it is layout, not data."""
    text = ANSI.sub('', transcript)
    found = None
    start = text.find(PREFIX)
    while start != -1:
        chars, i = [], start + len(PREFIX)
        while i < len(text) and len(chars) < 95:
            c = text[i]
            if c.isascii() and (c.isalnum() or c in '_-'):
                chars.append(c)
            elif not c.isspace():
                break
            i += 1
        candidate = PREFIX + ''.join(chars)
        if SHAPE.fullmatch(candidate):
            found = candidate
        start = text.find(PREFIX, start + 1)
    return found


def request(path, token, body):
    return urllib.request.Request('https://api.anthropic.com/v1/' + path, data=json.dumps(body).encode(), headers={
        'Authorization': 'Bearer ' + token, 'anthropic-version': '2023-06-01',
        'anthropic-beta': 'oauth-2025-04-20', 'content-type': 'application/json', 'User-Agent': 'n2-agents'})


def organization(token):
    """The token's organization, from a free token count."""
    body = {'model': PROBE_MODEL, 'messages': [{'role': 'user', 'content': 'hi'}]}
    with urllib.request.urlopen(request('messages/count_tokens', token, body), timeout=10) as response:
        return response.headers.get('anthropic-organization-id')


def allowance(token):
    """Plan usage from the rate-limit headers of a one-token request, in the
    shape of /api/oauth/usage. That endpoint refuses inference-only tokens."""
    body = {'model': PROBE_MODEL, 'max_tokens': 1, 'system': SYSTEM,
            'messages': [{'role': 'user', 'content': 'hi'}]}
    with urllib.request.urlopen(request('messages', token, body), timeout=10) as response:
        return from_headers(response.headers)


def from_headers(headers):
    result = {'_organization': headers.get('anthropic-organization-id')}
    for window, key in (('5h', 'five_hour'), ('7d', 'seven_day')):
        used = headers.get(f'anthropic-ratelimit-unified-{window}-utilization')
        reset = headers.get(f'anthropic-ratelimit-unified-{window}-reset')
        if used is None:
            continue
        result[key] = {'utilization': round(float(used) * 100, 1), 'resets_at': None if reset is None else
                       datetime.fromtimestamp(int(reset), timezone.utc).isoformat()}
    return result


def login_organization(cfg):
    """The organization of the slot's own sign-in, as Claude Code cached it."""
    try:
        with open(os.path.join(cfg, '.claude.json')) as f:
            return (json.load(f).get('oauthAccount') or {}).get('organizationUuid')
    except (OSError, ValueError, AttributeError):
        return None


def main():
    verb, cfg = sys.argv[1], sys.argv[2]
    try:
        run(verb, cfg)
    except ValueError:
        sys.exit(f'agents: {settings_path(cfg)} is not valid JSON; fix it and try again')


def run(verb, cfg):
    if verb == 'has':
        sys.exit(0 if read(cfg) else 1)
    if verb == 'clear':
        write(cfg, None)
        return
    if verb == 'capture':  # capture <cfg> <transcript>
        with open(sys.argv[3], errors='replace') as f:
            token = capture(f.read())
        if not token:
            sys.exit('agents: no token in the setup-token output')
        try:
            org = organization(token)
        except Exception:
            sys.exit('agents: the new token did not work against the Claude API')
        if org != login_organization(cfg):
            sys.exit("agents: the token belongs to a different account than this profile's sign-in; nothing was saved")
        write(cfg, token)
        return
    sys.exit('usage: claude-token.py has|clear|capture <slot dir> [transcript]')


if __name__ == '__main__':
    main()
