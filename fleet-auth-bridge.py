#!/usr/bin/env python3
"""Account-pinned app-server relay shared by N2 frontends.

The provider connection is already initialized and independently authenticated.
Only that connection sees owner tokens and renewal requests. Frontend IDs occupy
separate namespaces from N2's authentication/verification RPCs.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT=Path(__file__).resolve().parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

client=load('n2_bridge_client','fleet-auth-client.py')
runner=load('n2_bridge_runner','codex-run.py')
MAX_BYTES=4*1024*1024
METHODS={'account/read','account/rateLimits/read','config/read','configRequirements/read',
         'thread/start','thread/resume','thread/fork','thread/read','thread/list','thread/loaded/list',
         'thread/archive','thread/unarchive','thread/unsubscribe','thread/name/set',
         'turn/start','turn/steer','turn/interrupt','review/start','model/list','skills/list',
         'plugin/list','app/list','hooks/list','mcpServerStatus/list','experimentalFeature/list','collaborationMode/list'}


def valid_id(value):
    return type(value) is int or (isinstance(value,str) and 0<len(value)<=256)


def decode(raw):
    if len(raw)>MAX_BYTES:raise ValueError('message too large')
    value=json.loads(raw,object_pairs_hook=client.binding.owner.unique,
                     parse_constant=lambda _: (_ for _ in ()).throw(ValueError('invalid number')))
    if not isinstance(value,dict):raise ValueError('invalid message')
    return value


class Receipts:
    """Sanitized per-turn accounting from cumulative provider thread counters."""
    COUNTS=('inputTokens','cachedInputTokens','outputTokens','totalTokens')
    def __init__(self,journal,profile,account):
        self.journal=journal;self.profile=profile;self.account=account
        self.threads={};self.current=None

    def thread(self,identifier,model,fresh):
        self.threads[identifier]={'model':model,'requestedModel':None,'total':dict.fromkeys(self.COUNTS,0) if fresh else None}

    def begin(self,thread,model=None):
        if self.current is not None:raise ValueError('unfinished execution receipt')
        previous=self.threads[thread]
        requested=model if model is not None else previous['requestedModel']
        self.current={'thread':thread,'turn':None,'model':None if requested is not None else previous['model'],'requestedModel':requested,
                      'baseline':previous['total'],'total':None,'started':time.time(),
                      'task':str(uuid.uuid4()),'completion':None,'early':[]}
        # Commit before dispatch. A killed bridge leaves an explicitly unknown
        # outcome, and a later terminal receipt supersedes this same task.
        current=self.current
        self.journal.append('codex',self.profile,'execution-started',{
            'status':'execution-unconfirmed','identity':{'status':'verified','accountHash':self.account},
            'source':'codex-app-server','session':thread,'model':current['model'],
            'requestedModel':requested,'usageScope':'provider-turn','startedAt':current['started'],
            'attribution':dict(dict.fromkeys(self.COUNTS),task=current['task'])})

    def acknowledge(self,turn):
        current=self.current
        if not current or not isinstance(turn,dict) or not valid_id(turn.get('id')) or not isinstance(turn['id'],str):
            raise ValueError('invalid execution acknowledgement')
        current['turn']=turn['id']
        early=current.pop('early')
        for method,params in early:self.observe(method,params)

    def observe(self,method,params):
        current=self.current
        if not current or not isinstance(params,dict) or params.get('threadId')!=current['thread']:return
        if method not in ('thread/tokenUsage/updated','turn/completed','model/rerouted'):return
        if current['turn'] is None:
            if len(current['early'])>=128:raise ValueError('too many early execution events')
            current['early'].append((method,params));return
        turn=params.get('turn') if method=='turn/completed' else None
        identifier=turn.get('id') if isinstance(turn,dict) else params.get('turnId')
        if identifier!=current['turn']:return
        if method=='turn/completed':
            if turn.get('status') not in ('completed','failed','interrupted'):raise ValueError('invalid completion state')
            if current['completion'] is not None:raise ValueError('duplicate turn completion')
            current['completion']=turn
        elif method=='model/rerouted':current['model']=None
        else:
            usage=params.get('tokenUsage');total=usage.get('total') if isinstance(usage,dict) else None
            if not isinstance(total,dict):raise ValueError('invalid token counters')
            counts={key:total.get(key) for key in self.COUNTS}
            if any(type(value) is not int or value<0 or value>=2**63 for value in counts.values()):raise ValueError('invalid token counters')
            if counts['cachedInputTokens']>counts['inputTokens']:raise ValueError('invalid cached token count')
            current['total']=counts

    def finish(self,verified=True):
        current=self.current
        if current is None:return
        completion=current['completion'] or {'status':'interrupted'}
        counts=dict.fromkeys(self.COUNTS)
        baseline,total=current['baseline'],current['total']
        if baseline is not None and total is not None and all(total[k]>=baseline[k] for k in self.COUNTS):
            counts={k:total[k]-baseline[k] for k in self.COUNTS}
            if counts['cachedInputTokens']>counts['inputTokens']:counts=dict.fromkeys(self.COUNTS)
        if not verified:counts=dict.fromkeys(self.COUNTS)
        if current['turn'] is not None:
            self.threads[current['thread']]['total']=total
            self.threads[current['thread']]['model']=current['model']
            self.threads[current['thread']]['requestedModel']=current['requestedModel']
        error=completion.get('error');error=error if isinstance(error,dict) else {}
        code=error.get('codexErrorInfo')
        quota=verified and completion['status']=='failed' and code in ('usageLimitExceeded','rateLimitExceeded')
        success=verified and completion['status']=='completed'
        reset=runner.load('n2_receipt_rpc','codex-rpc.py').reported_quota_reset(error,time.time()) if quota else None
        data={'status':'restricted' if quota else ('ok' if success else 'execution-failed'),
              'identity':{'status':'verified','accountHash':self.account} if verified else {'status':'unknown'},
              'source':'codex-app-server','session':current['thread'],'model':current['model'],'requestedModel':current['requestedModel'],
              'usageScope':'provider-turn','startedAt':current['started'],
              'attribution':dict(counts,task=current['task'])}
        if quota:
            data.update(restrictions=[{'scope':'execution','reason':'quota-rejected','resetsAt':reset}],
                        resetKnown=reset is not None,recheckAt=reset)
        self.journal.append('codex',self.profile,'quota-rejected' if quota else ('execution-succeeded' if success else 'execution-failed'),data)
        self.current=None


class Bridge:
    def __init__(self,provider,emit,receipts=None):
        self.provider=provider;self.emit=emit;self.initialized=False;self.receipts=receipts
        self.sequence=0;self.pending={};self.approvals={};self.threads=set();self.active=False

    def key(self):
        self.sequence+=1;return 'n2-frontend-'+str(self.sequence)

    def error(self,request,message):
        self.emit({'id':request['id'],'error':{'code':-32602,'message':message}})

    def frontend(self,message):
        method=message.get('method')
        if method is None:
            key=message.get('id')
            if not isinstance(key,str) or key not in self.approvals:
                raise ValueError('unknown approval response')
            if ('result' in message)==('error' in message):raise ValueError('invalid approval response')
            result=dict(message,id=self.approvals.pop(key));self.provider.send(result);return
        if not isinstance(method,str):raise ValueError('invalid method')
        if method=='initialized' and 'id' not in message and self.initialized:return
        if not valid_id(message.get('id')):raise ValueError('request ID required')
        if method=='initialize':
            if self.initialized:raise ValueError('already initialized')
            self.initialized=True
            self.emit({'id':message['id'],'result':self.provider.initialization});return
        if not self.initialized:raise ValueError('initialize required')
        params=message.get('params') or {}
        if not isinstance(params,dict):raise ValueError('invalid parameters')
        if method.startswith('account/') and method not in ('account/read','account/rateLimits/read'):
            self.error(message,'Account management belongs to N2');return
        if method.startswith('config/') and method not in ('config/read','configRequirements/read'):
            self.error(message,'Change the N2 profile configuration outside this session');return
        if method not in METHODS:
            self.error(message,'Method is not supported by the account-bound bridge');return
        if method=='account/read':params=dict(params,refreshToken=False)
        requested_cwd=params.get('cwd')
        if requested_cwd is not None:
            if (not isinstance(requested_cwd,str) or not requested_cwd
                    or os.path.realpath(os.path.join(self.provider.cwd,requested_cwd))!=os.path.realpath(self.provider.cwd)):
                self.error(message,'Start a separate account-bound session for another working directory');return
            params=dict(params,cwd=self.provider.cwd)
        if 'threadId' in params and params['threadId'] not in self.threads:
            self.error(message,'Thread has no account binding in this session');return
        if method.startswith(('thread/','turn/','review/')):
            overrides=params.get('config')
            safe_overrides=(overrides is None or (isinstance(overrides,dict) and all(
                key=='web_search' and isinstance(value,str) and value in ('disabled','cached','live')
                for key,value in overrides.items())))
            if params.get('modelProvider') not in (None,'openai') or not safe_overrides:
                self.error(message,'This session must keep its selected account route');return
        if method in ('thread/resume','thread/fork','turn/start','turn/steer','review/start'):
            if params.get('threadId') not in self.threads:
                self.error(message,'Thread has no account binding in this session');return
        if method=='review/start' and params.get('delivery')=='detached':
            self.error(message,'Detached review requires a separate account-bound session');return
        if method in ('thread/start','thread/resume','thread/fork','turn/start','review/start'):
            if self.active or self.approvals:
                self.error(message,'Finish the current turn and approvals before starting another');return
            if self.pending:raise ValueError('verification requires drained requests')
            deferred=[]
            self.provider.validate_account_binding(deferred_messages=deferred)
            for notification in deferred:self.backend(notification)
            if self.active or self.approvals:
                self.error(message,'Finish the current turn and approvals before starting another');return
        key=self.key();self.pending[key]=(message['id'],method)
        if method in ('turn/start','review/start'):
            self.active=True
            if self.receipts:self.receipts.begin(params['threadId'],params.get('model'))
        try:self.provider.send(dict(message,id=key,params=params))
        except BaseException:
            self.pending.pop(key,None);raise

    def backend(self,message):
        method=message.get('method');identifier=message.get('id')
        if method=='account/chatgptAuthTokens/refresh' or method=='account/updated':
            # CodexRPC.receive must consume renewal or reject an account change.
            raise RuntimeError('unhandled account control message')
        if method is None:
            if not isinstance(identifier,str) or identifier not in self.pending:
                raise ValueError('unknown provider response')
            frontend_id,request_method=self.pending.pop(identifier)
            if request_method in ('turn/start','review/start'):
                if 'error' in message:
                    self.active=False
                    if self.receipts:self.receipts.finish()
                elif self.receipts:self.receipts.acknowledge(message.get('result',{}).get('turn'))
            if request_method in ('thread/start','thread/resume','thread/fork') and 'result' in message:
                result=message['result'];thread=result.get('thread') if isinstance(result,dict) else None
                if (not isinstance(thread,dict) or not isinstance(thread.get('id'),str) or not thread['id']
                        or result.get('modelProvider')!='openai' or result.get('cwd')!=self.provider.cwd):
                    raise RuntimeError('thread route does not match selected account')
                self.threads.add(thread['id'])
                if self.receipts:self.receipts.thread(thread['id'],result.get('model'),request_method=='thread/start')
            self.emit(dict(message,id=frontend_id));return
        if not isinstance(method,str):raise ValueError('invalid provider method')
        if self.receipts:self.receipts.observe(method,message.get('params'))
        if method=='turn/completed' and (self.receipts is None or (self.receipts.current and self.receipts.current['completion'])):self.active=False
        if 'id' in message:
            if not valid_id(identifier) or len(self.approvals)>=128:raise ValueError('invalid approval request')
            key=self.key();self.approvals[key]=identifier;message=dict(message,id=key)
        self.emit(message)


    def flush_receipts(self):
        if not self.receipts or not self.receipts.current or not self.receipts.current['completion']:return
        if self.pending or self.approvals:return
        deferred=[]
        self.provider.validate_account_binding(deferred_messages=deferred)
        for message in deferred:self.backend(message)
        self.receipts.finish()
        self.active=False


def serve(provider,source,sink,receipts=None):
    ingress=queue.Queue(maxsize=128);stopped=threading.Event()
    def read():
        try:
            while not stopped.is_set():
                raw=source.readline(MAX_BYTES+1)
                message=None if not raw else decode(raw)
                while not stopped.is_set():
                    try:ingress.put(message,timeout=.1);break
                    except queue.Full:continue
                if message is None:return
        except Exception:
            while not stopped.is_set():
                try:ingress.put(False,timeout=.1);return
                except queue.Full:continue
    def emit(message):
        raw=json.dumps(message,allow_nan=False,separators=(',',':')).encode()+b'\n'
        if len(raw)>MAX_BYTES:raise ValueError('response too large')
        sink.write(raw);sink.flush()
    reader=threading.Thread(target=read,daemon=True);reader.start()
    bridge=Bridge(provider,emit,receipts);waiting=[];eof=False;last_progress=time.monotonic()
    try:
        while True:
            if not provider.messages.empty():
                message=provider.receive(time.monotonic()+10,return_after_control=True)
                if message is not None:bridge.backend(message)
                last_progress=time.monotonic()
            try:
                message=ingress.get(timeout=.02)
                if message is False:raise ValueError('frontend stream invalid')
                if message is None:eof=True
                elif 'method' not in message:bridge.frontend(message)
                else:
                    if len(waiting)>=128:raise ValueError('too many frontend requests')
                    waiting.append(message)
            except queue.Empty:pass
            bridge.flush_receipts()
            if waiting and not bridge.pending:
                bridge.frontend(waiting.pop(0));last_progress=time.monotonic()
            if eof and not waiting and not bridge.pending:return
            if (waiting or bridge.pending) and time.monotonic()-last_progress>120:
                raise TimeoutError('frontend request timed out')
    finally:
        stopped.set()
        if receipts and receipts.current:receipts.finish(verified=False)


def terminal(provider,home,executable,arguments,receipts=None):
    # The directory restricts access to this user; there is no TCP listener or
    # bearer credential in command arguments, socket names or filesystem data.
    if any(arg=='--remote' or arg.startswith('--remote=') or arg.startswith('--remote-auth-token-env') for arg in arguments):
        raise ValueError('cannot override account-bound endpoint')
    with tempfile.TemporaryDirectory(prefix='n2-tui-',dir='/tmp') as directory:
        path=str(Path(directory)/'socket');listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        process=None;stream=None;connection=None;previous=signal.getsignal(signal.SIGINT)
        try:
            listener.bind(path);os.chmod(path,0o600);listener.listen(1);listener.settimeout(.2)
            environment=client.native.environment(home);environment['CODEX_HOME']=home
            for key in ('TERM','COLORTERM','TERM_PROGRAM'):
                if key in os.environ:environment[key]=os.environ[key]
            process=subprocess.Popen([executable,'--remote','unix://'+path,*arguments],env=environment)
            signal.signal(signal.SIGINT,signal.SIG_IGN)
            deadline=time.monotonic()+15
            while True:
                if process.poll() is not None:raise RuntimeError('terminal did not connect')
                if time.monotonic()>=deadline:raise TimeoutError('terminal did not connect')
                try:connection,_=listener.accept();break
                except socket.timeout:continue
            listener.close()
            stream=load('n2_private_websocket','fleet-auth-websocket.py').Stream(connection)
            serve(provider,stream,stream,receipts)
            stream.close();return process.wait(timeout=5)
        finally:
            signal.signal(signal.SIGINT,previous);listener.close()
            if stream is not None:stream.close()
            elif connection is not None:connection.close()
            if process is not None and process.poll() is None:
                process.terminate()
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:process.kill();process.wait()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',required=True);parser.add_argument('--profile',required=True)
    parser.add_argument('--config',required=True);parser.add_argument('--executable',default='codex')
    parser.add_argument('--tui',action='store_true');parser.add_argument('frontend_args',nargs=argparse.REMAINDER)
    args=parser.parse_args()
    def interrupted(*_):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupted)
    try:
        broker=client.for_profile(args.root,args.config,args.profile)
        journal=runner.load('n2_bridge_journal','usage-store.py').Journal(args.root,broker.recipient)
        receipts=Receipts(journal,args.profile,broker.record['accountHash'])
        with tempfile.TemporaryDirectory(prefix='n2-owner-session-') as directory:
            runner.prepare_home(Path(args.config).resolve(strict=True),Path(directory))
            with broker.connection(directory,os.getcwd(),time.monotonic()+20,executable=args.executable) as (provider,_):
                if args.tui:
                    arguments=args.frontend_args[1:] if args.frontend_args[:1]==['--'] else args.frontend_args
                    return terminal(provider,directory,args.executable,arguments,receipts)
                if args.frontend_args:raise ValueError('unexpected app-server arguments')
                serve(provider,sys.stdin.buffer,sys.stdout.buffer,receipts)
        return 0
    except (Exception,KeyboardInterrupt):
        print('agents: account-bound app-server unavailable',file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
