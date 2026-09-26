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
native_frontend = settings.get('nativeFrontend', False)
thread_id = '01990000-0000-7000-8000-000000000001' if native_frontend else 'fixture-thread'
home = Path(os.environ['CODEX_HOME'])
managed = 'cli_auth_credentials_store="file"' in sys.argv
if managed or not settings.get('allowExternalHome', False):
    assert not any(key in os.environ for key in ('OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'OPENAI_BASE_URL', 'HTTPS_PROXY'))
    assert os.environ['HOME'] == str(home)
token = None
turn_number = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    with (base/'trace.jsonl').open('a') as out:
        out.write(json.dumps({'method': method, 'managed': managed, 'home': str(home),
                              'refresh': request.get('params', {}).get('refreshToken')})+'\n')
    if 'id' not in request: continue
    result = {}
    if method == 'config/read':
        result = {'origins': {}, 'config': {'model_provider': 'other'} if managed and mode == 'wrong-provider' else {}}
    elif method == 'account/login/cancel':
        assert managed
        result={'status':'canceled'}
    elif method == 'account/login/start' and managed:
        assert request['params']=={'type':'chatgptDeviceCode'}
        assert not (home/'auth.json').exists()
        login_id='00000000-0000-4000-8000-000000000001'
        result={'type':'chatgptDeviceCode','loginId':login_id,
                'verificationUrl':'https://auth.openai.com/codex/device','userCode':'TEST-1234'}
        if mode=='login-bad-url':result['verificationUrl']='https://other.invalid/device'
        print(json.dumps({'id':request['id'],'result':result}),flush=True)
        if mode in ('login-cancel','login-timeout','login-bad-url'):continue
        if settings.get('loginDelay'):time.sleep(settings['loginDelay'])
        path=home/'auth.json'
        path.write_text(json.dumps({'tokens':{'access_token':'original-secret','account_id':'workspace'}}))
        path.chmod(0o600)
        params={'loginId':login_id,'success':True,'error':None}
        if mode=='login-wrong-id':params['loginId']='00000000-0000-4000-8000-000000000002'
        if mode=='login-error':params.update(success=False,error='sensitive-provider-diagnostic')
        print(json.dumps({'method':'account/login/completed','params':params}),flush=True)
        continue
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
        result = {'requiresOpenaiAuth': True, 'account': {'type': 'chatgpt', 'planType': 'plus', 'email': 'other@example.invalid' if (token == 'rotated-secret' and mode == 'wrong-account') or mode == 'login-other-account' else 'fixture@example.invalid'},
                  'workspaceRouting': {'chatgptAccountId': 'workspace', 'backendOrigin': 'https://chatgpt.com', 'accountRoutingOverride': 'NO_CONSTRAINT'}}
    elif method == 'thread/start':
        thread={'id':thread_id,'sessionId':thread_id,'cliVersion':'0.157.1',
                'createdAt':int(time.time()),'updatedAt':int(time.time()),'cwd':os.getcwd(),
                'ephemeral':True,'modelProvider':'openai','preview':'fixture','projectId':None,
                'source':'cli','status':{'type':'idle'},'turns':[]}
        result={'thread':thread,'modelProvider':'openai','cwd':os.getcwd(),'model':'fixture-model',
                'approvalPolicy':'never','approvalsReviewer':'user','sandbox':{'type':'readOnly'}}
        if native_frontend:
            print(json.dumps({'id':request['id'],'result':result}),flush=True)
            print(json.dumps({'method':'thread/started','params':{'thread':thread}}),flush=True)
            continue
    elif method == 'turn/start':
        turn_number+=1
        turn_id='fixture-turn-'+str(turn_number)
        print(json.dumps({'id':request['id'],'result':{'turn':{'id':turn_id,'items':[],'status':'inProgress'}}}),flush=True)
        if native_frontend:
            print(json.dumps({'method':'turn/started','params':{'threadId':thread_id,'turn':{'id':turn_id,'items':[],'status':'inProgress'}}}),flush=True)
            item={'type':'agentMessage','id':'fixture-message','text':'','phase':'final_answer'}
            print(json.dumps({'method':'item/started','params':{'threadId':thread_id,'turnId':turn_id,'item':item}}),flush=True)
            item['text']='N2 native frontend fixture completed'
            print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':thread_id,'turnId':turn_id,'itemId':item['id'],'delta':item['text']}}),flush=True)
            print(json.dumps({'method':'item/completed','params':{'threadId':thread_id,'turnId':turn_id,'item':item}}),flush=True)
        counts={'inputTokens':50*turn_number,'cachedInputTokens':30*turn_number,'outputTokens':10*turn_number,'totalTokens':60*turn_number}
        print(json.dumps({'method':'thread/tokenUsage/updated','params':{'threadId':thread_id,'turnId':turn_id,'tokenUsage':{'total':dict(counts,reasoningOutputTokens=0),'last':dict(counts,reasoningOutputTokens=0)}}}),flush=True)
        turn={'id':turn_id,'status':'completed','items':[]}
        if turn_number==settings.get('quotaTurn'):
            turn.update(status='failed',error={'codexErrorInfo':'usageLimitExceeded','message':'private quota diagnostic'})
        print(json.dumps({'method':'turn/completed','params':{'threadId':thread_id,'turn':turn}}),flush=True)
        continue
    elif method == 'account/rateLimits/read':
        if settings.get('rejectInitial') and (token == 'original-secret' or settings.get('rejectEveryToken')):
            print(json.dumps({'id':900,'method':'account/chatgptAuthTokens/refresh',
                              'params':{'reason':'unauthorized','previousAccountId':'workspace'}}),flush=True)
            continue
        if mode == 'verification-error':
            print(json.dumps({'id': request['id'], 'error': {'message': 'sensitive-provider-diagnostic'}}), flush=True)
            continue
        result = {'accountId': 'workspace', 'rateLimits': {'primary': {'usedPercent': 12}}}
    elif method == 'model/list':
        result={'data':[{'id':'fixture-model','model':'fixture-model','displayName':'Fixture',
                        'description':'Synthetic provider','isDefault':True,'hidden':False,
                        'defaultReasoningEffort':'medium',
                        'supportedReasoningEfforts':[{'reasoningEffort':'medium','description':'Medium'}]}]}
    elif method == 'configRequirements/read':result={'requirements':None}
    elif method in ('skills/list','app/list','mcpServerStatus/list','thread/loaded/list','thread/list','hooks/list'):
        result={'data':[]}
    elif method == 'turn/interrupt':result={}
    elif method == 'thread/unsubscribe':result={'status':'unsubscribed'}
    elif method == 'plugin/list':result={'marketplaces':[]}
    elif method in ('experimentalFeature/list','collaborationMode/list'):result={'data':[]}
    else:
        assert method == 'initialize', method
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
