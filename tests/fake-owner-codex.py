#!/usr/bin/env python3
"""Disposable owner protocol fixture; never calls a provider."""
import json
import os
from pathlib import Path
import sys
import time

base = Path(__file__).resolve().parent
settings = json.loads((base/'settings.json').read_text())
mode = settings.get('mode', '')
home = Path(os.environ['CODEX_HOME'])
managed = 'cli_auth_credentials_store="file"' in sys.argv
if managed or not settings.get('allowExternalHome', False):
    assert not any(key in os.environ for key in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'OPENAI_BASE_URL', 'HTTPS_PROXY'))
    assert os.environ['HOME'] == str(home)
token = None
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    with (base/'trace.jsonl').open('a') as out:
        out.write(json.dumps({'method': method, 'managed': managed, 'home': str(home),
                              'refresh': request.get('params', {}).get('refreshToken')})+'\n')
    if 'id' not in request: continue
    result = {}
    if method == 'config/read':
        result = {'config': {'model_provider': 'other'} if managed and mode == 'wrong-provider' else {}}
    elif method == 'account/login/start':
        assert not managed
        token = request['params']['accessToken']
        assert not (home/'auth.json').exists()
        result = {'type': 'chatgptAuthTokens'}
    elif method == 'account/read':
        if request.get('params', {}).get('refreshToken'):
            assert managed
            grant = json.loads((home.parent/'state.json').read_text())
            assert grant['state'] == 'renewing'
            if mode == 'timeout': time.sleep(30)
            if mode != 'unchanged':
                path=home/'auth.json'
                path.write_text(json.dumps({'tokens': {'access_token': settings.get('replacementToken', 'rotated-secret'), 'account_id': 'workspace'}}))
                path.chmod(0o600)
            if mode == 'orphan':
                (base/'refresh-started').write_text(str(os.getpid()))
                time.sleep(30)
            if mode == 'error-after-save':
                print(json.dumps({'id': request['id'], 'error': {'message': 'sensitive-provider-diagnostic'}}), flush=True)
                continue
        result = {'account': {'type': 'chatgpt', 'email': 'other@example.invalid' if token == 'rotated-secret' and mode == 'wrong-account' else 'fixture@example.invalid'},
                  'workspaceRouting': {'chatgptAccountId': 'workspace', 'backendOrigin': 'https://chatgpt.com'}}
    elif method == 'account/rateLimits/read':
        if settings.get('rejectInitial') and (token == 'original-secret' or settings.get('rejectEveryToken')):
            print(json.dumps({'id':900,'method':'account/chatgptAuthTokens/refresh',
                              'params':{'reason':'unauthorized','previousAccountId':'workspace'}}),flush=True)
            continue
        if mode == 'verification-error':
            print(json.dumps({'id': request['id'], 'error': {'message': 'sensitive-provider-diagnostic'}}), flush=True)
            continue
        result = {'accountId': 'workspace', 'rateLimits': {'primary': {'usedPercent': 12}}}
    else:
        assert method == 'initialize', method
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
