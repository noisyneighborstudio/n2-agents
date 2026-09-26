#!/usr/bin/env python3
"""Synthetic app-server for account-bound execution tests. Never contacts a model."""
import json
import os
from pathlib import Path
import sys
import time

mode = os.environ.get('N2_BOUND_FIXTURE', '')
trace = Path(os.environ['N2_BOUND_TRACE'])

def send(value):
    print(json.dumps(value), flush=True)

def notice(method, params):
    send({'method': method, 'params': params})

for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    with trace.open('a') as out:
        out.write(json.dumps({'method': method, 'home': os.environ['CODEX_HOME'],
                              'args': sys.argv[1:], 'cwd': os.getcwd()}) + '\n')
    if 'id' not in request:
        continue
    result = {}
    if method == 'account/login/start':
        result = {'type': 'chatgptAuthTokens'}
        notice('account/updated', {'authMode': 'chatgptAuthTokens'})
    elif method == 'config/read':
        result = {'config': {}}
    elif method == 'account/read':
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.invalid'},
                  'workspaceRouting': {'chatgptAccountId': 'workspace', 'backendOrigin': 'https://chatgpt.com'}}
    elif method == 'account/rateLimits/read':
        result = {'accountId': 'workspace', 'rateLimits': {'primary': {'usedPercent': 12}}}
    elif method == 'thread/start':
        params = request['params']
        assert params['approvalPolicy'] == 'on-request'
        assert params['approvalsReviewer'] == 'auto_review'
        assert params['sandbox'] == 'workspace-write'
        result = {'thread': {'id': 'thread-fixture'}, 'cwd': os.getcwd(), 'modelProvider': 'openai',
                  'model': 'fixture-model', 'approvalPolicy': 'on-request', 'approvalsReviewer': 'auto_review',
                  'sandbox': {'type': 'workspaceWrite'}}
        if mode == 'wrong-provider': result['modelProvider'] = 'other'
        if mode == 'wrong-sandbox': result['sandbox'] = {'type': 'dangerFullAccess'}
    elif method == 'turn/start':
        assert request['params']['threadId'] == 'thread-fixture'
        assert request['params']['effort'] in ('low', 'medium', 'high')
        params = {'threadId': 'thread-fixture', 'turnId': 'turn-fixture'}
        if mode == 'refresh':
            send({'id': 90, 'method': 'account/chatgptAuthTokens/refresh', 'params': {'previousAccountId': 'workspace'}})
            continue
        if mode == 'account-change':
            notice('account/updated', {'authMode': 'chatgpt'})
            continue
        if mode == 'approval':
            send({'id': 90, 'method': 'item/commandExecution/requestApproval', 'params': params})
            continue
        if mode == 'slow':
            Path(os.environ['N2_BOUND_STARTED']).write_text(str(os.getpid()))
            time.sleep(60)
        # Deliberately send events before the turn/start response.
        notice('item/completed', dict(params, item={'type': 'agentMessage', 'text': 'Try again in 1 minute' if mode.startswith('quota') else 'Bound answer'}))
        counts = {'inputTokens': 50, 'cachedInputTokens': 30, 'outputTokens': 10, 'totalTokens': 60}
        if mode == 'bad-tokens': counts['inputTokens'] = True
        notice('thread/tokenUsage/updated', dict(params, tokenUsage={'total': counts}))
        notice('thread/tokenUsage/updated', {'threadId': 'unrelated', 'turnId': 'unrelated', 'tokenUsage': {'total': {'inputTokens': 999}}})
        if mode == 'rerouted': notice('model/rerouted', dict(params, toModel='other-model'))
        completed = {'id': 'turn-fixture', 'status': 'failed' if mode.startswith('quota') else 'completed', 'items': []}
        if mode.startswith('quota'):
            message = 'not copied'
            if mode == 'quota-reset': message += '. Try again in 3 minutes.'
            if mode == 'quota-ambiguous': message += '. Try again at Sep 26th, 2026 11:20 AM.'
            completed['error'] = {'codexErrorInfo': 'usageLimitExceeded', 'message': message}
        notice('turn/completed', {'threadId': 'thread-fixture', 'turn': completed})
        result = {'turn': {'id': 'turn-fixture', 'status': 'inProgress', 'items': []}}
    send({'id': request['id'], 'result': result})
