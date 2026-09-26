#!/usr/bin/env python3
"""Provider usage readers. Stdout contains sanitized measurements only."""
import hashlib, importlib.util, json, math, os, signal, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
from datetime import datetime, timezone

def claude_creds(cfg, is_default):
    # agents run always sets CLAUDE_CONFIG_DIR to this literal path. Other
    # paths and the unscoped Keychain entry can belong to different accounts.
    if any(os.environ.get(k) for k in ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')):
        return None, 'credential-override'
    secure_dir = os.environ.get('CLAUDE_SECURESTORAGE_CONFIG_DIR', cfg)
    if secure_dir != cfg:
        return None, 'credential-override'
    svc = 'Claude Code-credentials-' + hashlib.sha256(cfg.encode()).hexdigest()[:8]
    result = subprocess.run(['security', 'find-generic-password', '-s', svc, '-w'],
                            capture_output=True, text=True, timeout=5)
    credential = None
    if result.returncode == 0:
        try:
            credential = json.loads(result.stdout).get('claudeAiOauth')
        except (ValueError, AttributeError):
            return None, 'fetch-error'
    elif result.returncode not in (1, 44):
        return None, 'credential-store-unavailable'
    if not credential:
        try:
            with open(os.path.join(cfg, '.credentials.json')) as f:
                credential = json.load(f).get('claudeAiOauth')
        except (OSError, ValueError, AttributeError):
            pass
    if not isinstance(credential, dict) or not credential.get('accessToken'):
        return None, 'no-token'
    expires = credential.get('expiresAt')
    if not isinstance(expires, (int, float)):
        return None, 'stale-token'
    return credential, 'ok' if expires / 1000 > time.time() else 'stale-token'

def claude_identity(cfg):
    """Ask the provider CLI which login its literal configured route selects."""
    with tempfile.TemporaryDirectory(prefix='n2-claude-identity-') as cwd:
        try:
            result = subprocess.run(['claude', 'auth', 'status', '--json'],
                                    env=dict(os.environ, CLAUDE_CONFIG_DIR=cfg), cwd=cwd,
                                    capture_output=True, text=True, timeout=10)
            value = json.loads(result.stdout)
            if result.returncode != 0 or not isinstance(value, dict) or not value.get('loggedIn'):
                return {'status': 'unavailable'}
            if value.get('authMethod') != 'claude.ai' or value.get('apiProvider') != 'firstParty':
                return {'status': 'conflicting'}
            email, organization = value.get('email'), value.get('orgId')
            if not isinstance(email, str) or not email:
                return {'status': 'unknown'}
            identity = {'status': 'login-only', 'loginHash': hashlib.sha256(email.lower().encode()).hexdigest()}
            if isinstance(organization, str) and organization:
                key = json.dumps(['claude', organization, email.lower()], separators=(',', ':'))
                identity.update(status='verified', accountHash=hashlib.sha256(key.encode()).hexdigest(),
                                organizationHash=hashlib.sha256(organization.encode()).hexdigest())
            return identity
        except (OSError, ValueError, subprocess.SubprocessError):
            return {'status': 'unavailable'}


def claude(name, cfg):
    c, status = claude_creds(cfg, name == 'Default')
    if status != 'ok':
        return status, None
    identity = claude_identity(cfg)
    if identity['status'] == 'conflicting':
        return 'credential-override', None
    current, current_status = claude_creds(cfg, name == 'Default')
    if current_status != 'ok' or current != c:
        return 'fetch-error', None
    request = urllib.request.Request('https://api.anthropic.com/api/oauth/usage',
        headers={'Authorization': 'Bearer ' + c['accessToken'],
                 'anthropic-beta': 'oauth-2025-04-20', 'User-Agent': 'n2-agents'})
    def read():
        result = json.load(urllib.request.urlopen(request, timeout=10))
        if not isinstance(result, dict):
            raise ValueError('invalid usage response')
        result['_identity'] = identity
        return result
    return 'ok', read

def claude_row(r):
    five, seven = r.get('five_hour') or {}, r.get('seven_day') or {}
    return (five.get('utilization', '-'), seven.get('utilization', '-'),
            (five.get('resets_at') or '-')[:16], (seven.get('resets_at') or '-')[:16])

def codex_native(cfg):
    """Read the CLI's selected account and all limit buckets, including keyring auth."""
    import queue
    messages = queue.Queue()
    env = dict(os.environ, CODEX_HOME=cfg)
    with tempfile.TemporaryDirectory(prefix='n2-codex-usage-') as cwd:
        p = subprocess.Popen(['codex', 'app-server'], cwd=cwd, env=env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        def reader():
            for line in p.stdout:
                try:
                    message = json.loads(line)
                    if isinstance(message, dict):
                        messages.put(message)
                except ValueError:
                    pass
            messages.put(None)
        worker = threading.Thread(target=reader, daemon=True)
        worker.start()
        deadline = time.monotonic() + 15
        def send(message):
            p.stdin.write(json.dumps(message) + '\n')
            p.stdin.flush()
        def receive(wanted):
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError('app-server read timed out')
                message = messages.get(timeout=max(0.01, deadline - time.monotonic()))
                if message is None:
                    raise RuntimeError('app-server closed')
                if message.get('id') == wanted:
                    if 'error' in message:
                        raise RuntimeError('app-server read failed')
                    return message.get('result') or {}
        try:
            send({'id': 1, 'method': 'initialize', 'params': {
                'clientInfo': {'name': 'n2_usage', 'version': '1.0.0'},
                'capabilities': {'experimentalApi': True}}})
            receive(1)
            send({'method': 'initialized'})
            send({'id': 2, 'method': 'account/read', 'params': {'refreshToken': False}})
            account_response = receive(2)
            account = account_response.get('account')
            if not account or account.get('type') != 'chatgpt':
                return {'_native': True, '_status': 'no-token' if not account else 'no-usage-api', 'account': account}
            send({'id': 3, 'method': 'account/rateLimits/read'})
            result = receive(3)
            send({'id': 4, 'method': 'account/read', 'params': {'refreshToken': False}})
            if receive(4) != account_response:
                raise RuntimeError('account changed during usage read')
            result['_native'] = True
            result['account'] = account
            result['workspaceRouting'] = account_response.get('workspaceRouting')
            return result
        finally:
            try:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=2)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                if p.poll() is None:
                    os.killpg(p.pid, signal.SIGKILL)
                    p.wait(timeout=2)
            p.stdin.close()
            p.stdout.close()
            worker.join(timeout=1)


def number(value):
    import math
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value if math.isfinite(value) and 0 <= value <= 100 else None


def details(vendor, data):
    """Whitelist measurement fields; never serialize a provider response wholesale."""
    result = {'windows': [], 'restrictions': [], 'credits': {},
              'identity': {'status': 'unknown'}, 'source': vendor + '-usage'}
    def window(scope, value, seconds=None, native=False):
        if not isinstance(value, dict):
            return
        used = number(value.get('usedPercent' if native else 'used_percent', value.get('utilization')))
        duration = value.get('windowDurationMins') if native else value.get('limit_window_seconds', seconds)
        if native and isinstance(duration, (int, float)):
            duration *= 60
        if not isinstance(duration, (int, float)) or isinstance(duration, bool) or not math.isfinite(duration) or duration <= 0:
            duration = None
        reset = value.get('resetsAt' if native else 'reset_at', value.get('resets_at'))
        if not isinstance(reset, (str, int, float)) or isinstance(reset, bool) or (isinstance(reset, (int, float)) and not math.isfinite(reset)):
            reset = None
        result['windows'].append({'scope': scope, 'usedPercent': used,
                                  'durationSeconds': duration, 'resetsAt': reset})
    if vendor == 'codex':
        native = data.get('_native', False)
        result['source'] = 'codex-app-server' if native else 'codex-usage-endpoint'
        if native:
            account = data.get('account') or {}
            # Native account/read identifies the login, but does not always
            # expose the workspace/account ID. Never equate email with quota scope.
            email = account.get('email')
            if isinstance(email, str) and email:
                result['identity'] = {'status': 'login-only', 'loginHash': hashlib.sha256(email.lower().encode()).hexdigest()}
                routing = data.get('workspaceRouting')
                if isinstance(routing, dict):
                    workspace = routing.get('chatgptAccountId')
                    origin = routing.get('backendOrigin')
                    if isinstance(workspace, str) and workspace and isinstance(origin, str) and origin.startswith('https://'):
                        # Quotas can differ between users in one workspace. Both
                        # login and selected workspace belong in the binding.
                        key = json.dumps(['codex', origin.rstrip('/'), workspace, email.lower()], separators=(',', ':'))
                        result['identity'].update(status='verified', accountHash=hashlib.sha256(key.encode()).hexdigest(),
                                                  organizationHash=hashlib.sha256(workspace.encode()).hexdigest())

            buckets = data.get('rateLimitsByLimitId')
            if not isinstance(buckets, dict) or not buckets:
                single = data.get('rateLimits') or {}
                buckets = {single.get('limitId') or 'codex': single}
        else:
            buckets = {'codex': data.get('rate_limit') or {}}
            extra = data.get('additional_rate_limits') or []
            if isinstance(extra, list):
                for i, item in enumerate(extra):
                    if isinstance(item, dict):
                        buckets[str(item.get('limit_name') or item.get('limit_id') or i)] = item.get('rate_limit') or item
        for scope, bucket in buckets.items():
            if not isinstance(bucket, dict):
                continue
            for key in (('primary', 'secondary') if native else ('primary_window', 'secondary_window')):
                window(str(scope) + ':' + key, bucket.get(key), native=native)
            reached = bucket.get('rateLimitReachedType') if native else bucket.get('limit_reached') or bucket.get('allowed') is False
            if reached:
                result['restrictions'].append({'scope': str(scope), 'reason': str(reached) if native else 'limit-reached'})
            credits = bucket.get('credits') or {}
            if isinstance(credits, dict):
                result['credits'][str(scope)] = {k: credits[k] for k in ('hasCredits', 'unlimited', 'balance')
                                               if k in credits and isinstance(credits[k], (bool, int, float, str))
                                               and (not isinstance(credits[k], float) or math.isfinite(credits[k]))}
    elif vendor == 'claude':
        result['identity'] = data.get('_identity', {'status': 'unknown'})
        for key, value in data.items():
            if key == 'five_hour' or key.startswith('seven_day'):
                window(key, value, 18000 if key == 'five_hour' else 604800)
        extra = data.get('extra_usage') or {}
        if isinstance(extra, dict):
            result['credits']['overage'] = {k: extra[k] for k in ('is_enabled', 'monthly_limit', 'used_credits', 'utilization', 'disabled_reason', 'spend_limit_reached')
                                           if k in extra and isinstance(extra[k], (bool, int, float, str))
                                           and (not isinstance(extra[k], float) or math.isfinite(extra[k]))}
        # Disabled overage is not itself a block on included allowance.
    return result


def codex_native_row(data):
    windows = details('codex', data)['windows']
    def column(seconds):
        found = [w for w in windows if w['durationSeconds'] == seconds and w['usedPercent'] is not None]
        if not found:
            return '-', '-'
        binding = max(found, key=lambda w: w['usedPercent'])
        reset = binding['resetsAt']
        return binding['usedPercent'], time.strftime('%Y-%m-%dT%H:%M', time.gmtime(reset)) if isinstance(reset, (int, float)) else '-'
    five, seven = column(18000), column(604800)
    return five[0], seven[0], five[1], seven[1]


def codex(name, cfg):
    if not os.environ.get('N2_CODEX_USAGE_URL'):
        return 'ok', lambda: codex_native(cfg)
    # An API-key login has no plan quota to read, and no tokens.
    try:
        t = json.load(open(cfg + '/auth.json')).get('tokens') or {}
    except (OSError, ValueError):
        t = {}
    if not t.get('access_token'):
        return 'no-token', None
    url = os.environ.get('N2_CODEX_USAGE_URL', 'https://chatgpt.com/backend-api/wham/usage')
    return 'ok', urllib.request.Request(url,
        headers={'Authorization': 'Bearer ' + t['access_token'],
                 'ChatGPT-Account-Id': t.get('account_id', ''), 'User-Agent': 'n2-agents'})

def codex_row(r):
    if r.get('_native'):
        return codex_native_row(r)
    # Plans differ in which windows they have (a 5-hour one, a weekly one, or
    # both), so each window is placed by its length, not its position.
    rl = r.get('rate_limit') or {}
    cols = {}
    for w in (rl.get('primary_window'), rl.get('secondary_window')):
        if w:
            used = 100 if rl.get('limit_reached') else w.get('used_percent', '-')
            reset = time.strftime('%Y-%m-%dT%H:%M', time.gmtime(w['reset_at'])) if w.get('reset_at') else '-'
            cols['five' if w.get('limit_window_seconds', 0) <= 5 * 3600 else 'seven'] = (used, reset)
    five, seven = cols.get('five', ('-', '-')), cols.get('seven', ('-', '-'))
    return five[0], seven[0], five[1], seven[1]

def grok(name, cfg):
    # Signed in = an auth.x.ai entry in the slot's auth.json. Its key lasts six
    # hours, so the read goes through the CLI, which renews it on the way.
    try:
        a = json.load(open(cfg + '/auth.json'))
    except (OSError, ValueError):
        a = {}
    if not any(k.startswith('https://auth.x.ai::') and v.get('key') for k, v in a.items()):
        return 'no-token', None
    return 'ok', lambda: grok_billing(cfg)

def grok_billing(cfg):
    # grok's own billing call over ACP (JSON-RPC on stdio), pinned to the slot.
    # Only the replies are parsed: its startup notices carry MCP servers' env.
    # SIGTERM ends it in ~1.5 s (closing stdin takes 4); SIGKILL if it hangs.
    p = subprocess.Popen(['grok', 'agent', 'stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, cwd=tempfile.gettempdir(),
                         env=dict(os.environ, GROK_HOME=cfg), start_new_session=True)
    kill = lambda sig: os.killpg(p.pid, sig)
    timer = threading.Timer(20, kill, (signal.SIGKILL,))
    timer.start()
    def call(i, method, params):
        p.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params}) + '\n')
        p.stdin.flush()
        for line in p.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if isinstance(m, dict) and m.get('id') == i:
                if 'result' not in m:
                    raise RuntimeError(m.get('error'))
                return m['result']
        raise RuntimeError('grok exited')
    try:
        call(1, 'initialize', {'protocolVersion': 1, 'clientCapabilities': {}})
        return call(2, '_x.ai/billing', {})
    finally:
        timer.cancel()
        try:
            kill(signal.SIGTERM)
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            kill(signal.SIGKILL)
            p.wait()
        except ProcessLookupError:
            p.wait()

def grok_row(r):
    # One credit pool per billing period (a week on today's plans) and no
    # 5-hour window, so it fills the 7d column alone.
    c = r.get('config') or {}
    end = (c.get('currentPeriod') or {}).get('end') or c.get('billingPeriodEnd')
    reset = datetime.fromisoformat(end.replace('Z', '+00:00')).astimezone(timezone.utc) \
        .strftime('%Y-%m-%dT%H:%M') if end else '-'
    return '-', c.get('creditUsagePercent', '-'), '-', reset

def muse(name, cfg):
    # A profile's login is in its slot's auth.json (the file backend N2 pins);
    # Default's is the one keychain item a plain `muse` uses. Never the
    # keychain for a profile: that would show Default's numbers under its name.
    try:
        t = (json.load(open(cfg + '/auth.json')).get('providers') or {}).get('meta', {}).get('access_token', '')
    except (OSError, ValueError):
        t = ''
    if not t and name == 'Default':
        p = subprocess.run(['security', 'find-generic-password', '-s', 'ai.meta.dev.credentials',
                            '-a', 'meta', '-w'], capture_output=True, text=True)
        try:
            t = json.loads(p.stdout).get('access_token', '') if p.returncode == 0 else ''
        except ValueError:
            t = ''
    if not t.startswith('dca:'):
        return 'no-token', None
    url = os.environ.get('N2_MUSE_USAGE_URL', 'https://api.meta.ai/muse-code/key')
    return 'ok', urllib.request.Request(url, data=b'{}', method='POST',
        headers={'Authorization': 'Bearer ' + t, 'x-api-version': '1.0.0',
                 'Content-Type': 'application/json', 'User-Agent': 'n2-agents'})

def muse_row(r):
    # The key endpoint (it mints an inference key we drop) reports both
    # windows: `window` is the 5-hour one, `weekly` the week.
    u = r.get('subs_usage') or {}
    cols = []
    for w in (u.get('window') or {}, u.get('weekly') or {}):
        at = w.get('resets_at')
        cols.append((w.get('used_percent', '-'),
                     time.strftime('%Y-%m-%dT%H:%M', time.gmtime(at)) if at else '-'))
    return cols[0][0], cols[1][0], cols[0][1], cols[1][1]

def cursor(name, cfg):
    # cursor-agent keeps ONE login in the keychain whatever CURSOR_CONFIG_DIR
    # says, so there is one account to read. It's shown once, on Default;
    # other slots say they share it rather than repeat the numbers.
    if name != 'Default':
        return 'shared-login', None
    p = subprocess.run(['security', 'find-generic-password', '-s', 'cursor-access-token',
                        '-a', 'cursor-user', '-w'], capture_output=True, text=True)
    if p.returncode != 0 or not p.stdout.strip():
        return 'no-token', None
    url = os.environ.get('N2_CURSOR_USAGE_URL',
                         'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage')
    return 'ok', urllib.request.Request(url, data=b'{}', method='POST',
        headers={'Authorization': 'Bearer ' + p.stdout.strip(), 'Content-Type': 'application/json',
                 'Connect-Protocol-Version': '1', 'User-Agent': 'n2-agents'})

def cursor_row(r):
    # One pool per monthly billing cycle, in the long-window column; the
    # percent is already in percent units (0.4 means 0.4%).
    end = r.get('billingCycleEnd')
    reset = time.strftime('%Y-%m-%dT%H:%M', time.gmtime(int(end) / 1000)) if end else '-'
    return '-', (r.get('planUsage') or {}).get('totalPercentUsed', '-'), '-', reset

def main():
    vendor = sys.argv[1]
    request, row = {'claude': (claude, claude_row), 'codex': (codex, codex_row),
                    'grok': (grok, grok_row), 'muse': (muse, muse_row),
                    'cursor': (cursor, cursor_row)}[vendor]
    for pair in sys.argv[2:]:
        name, cfg = pair.split('=', 1)
        columns = ('-', '-', '-', '-')
        measurement = details(vendor, {})
        try:
            status, req = request(name, cfg)
            if status == 'ok':
                data = req() if callable(req) else json.load(urllib.request.urlopen(req, timeout=10))
                if not isinstance(data, dict):
                    raise ValueError('invalid response')
                measurement = details(vendor, data)
                columns = row(data)
                status = data.get('_status', 'ok')
                extra_windows = [w for w in measurement['windows']
                                 if w['usedPercent'] is not None and w['usedPercent'] >= 95
                                 and (w['durationSeconds'] not in (18000, 604800)
                                      or (vendor == 'claude' and w['scope'] not in ('five_hour', 'seven_day')))]
                if measurement['restrictions'] or extra_windows:
                    status = 'restricted'
        except urllib.error.HTTPError as e:
            status = {429: 'rate-limited', 401: 'stale-token', 403: 'stale-token'}.get(e.code, 'fetch-error')
        except Exception:
            status = 'fetch-error'
        five, seven, five_at, seven_at = columns
        measurement['status'] = status
        measurement['display'] = {'shortUsed': five, 'longUsed': seven,
                                  'shortResets': five_at, 'longResets': seven_at}
        if os.environ.get('N2_USAGE_ROOT'):
            try:
                module_spec = importlib.util.spec_from_file_location('usage_store', os.path.join(os.path.dirname(__file__), 'usage-store.py'))
                journal_module = importlib.util.module_from_spec(module_spec)
                module_spec.loader.exec_module(journal_module)
                journal = journal_module.Journal(os.environ['N2_USAGE_ROOT'], os.environ.get('N2_USAGE_ORIGIN') or None)
                journal.append(vendor, name, 'measurement', measurement)
                journal.db.close()
            except Exception:
                print('agents: could not retain usage observation', file=sys.stderr)
        if os.environ.get('N2_USAGE_FORMAT') == 'json':
            measurement.update({'schemaVersion': 1, 'provider': vendor, 'profile': name,
                                'observedAt': datetime.now(timezone.utc).isoformat(), 'status': status,
                                'display': {'shortUsed': five, 'longUsed': seven,
                                            'shortResets': five_at, 'longResets': seven_at}})
            print(json.dumps(measurement, allow_nan=False, separators=(',', ':')))
        elif status not in ('ok', 'restricted'):
            print(f"{name}\t-\t-\t-\t{status}")
        else:
            print(f"{name}\t{five}\t{seven}\t{five_at}\t{status}\t{seven_at}")

if __name__ == "__main__":
    main()
