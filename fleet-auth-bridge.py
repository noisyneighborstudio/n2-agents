#!/usr/bin/env python3
"""Account-pinned app-server relay shared by N2 frontends.

The provider connection is already initialized and independently authenticated.
Only that connection sees owner tokens and renewal requests. Frontend IDs occupy
separate namespaces from N2's authentication/verification RPCs.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import select
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



class Sessions:
    """Private local history and immutable thread-to-owner bindings."""
    def __init__(self,root):
        self.base=Path(root).resolve(strict=True)/'codex-sessions'
        self.owner=client.binding.owner
        for path in (self.base,self.base/'threads',self.base/'homes'):
            self.owner.private_directory(path,create=True)

    def thread_path(self,thread):
        if not isinstance(thread,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,256}',thread):
            raise ValueError('invalid session identifier')
        return self.base/'threads'/hashlib.sha256(thread.encode()).hexdigest()

    def read(self,thread):
        raw=self.owner.private_file(self.thread_path(thread),16384)
        value=json.loads(raw,object_pairs_hook=self.owner.unique)
        if (not isinstance(value,dict) or set(value)!={'schemaVersion','thread','record','cwd'}
                or type(value['schemaVersion']) is not int or value['schemaVersion']!=1
                or value['thread']!=thread or not isinstance(value['cwd'],str)
                or not os.path.isabs(value['cwd'])):
            raise ValueError('invalid session binding')
        record=value['record']
        client.binding.validate(record,record.get('profileId') if isinstance(record,dict) else None)
        return value

    def remember(self,thread,record,cwd):
        value={'schemaVersion':1,'thread':thread,'record':record,'cwd':os.path.realpath(cwd)}
        raw=json.dumps(value,sort_keys=True,separators=(',',':')).encode()
        path=self.thread_path(thread)
        # Publish only complete records; a collision can never rebind a thread.
        fd,name=tempfile.mkstemp(prefix='.pending-',dir=path.parent)
        try:
            with os.fdopen(fd,'wb') as stream:
                stream.write(raw);stream.flush();os.fsync(stream.fileno())
            try:os.link(name,path)
            except FileExistsError:
                if self.read(thread)!=value:raise ValueError('session binding changed')
            finally:os.unlink(name)
            self.owner.sync_directory(path.parent)
        finally:
            if os.path.exists(name):os.unlink(name)

    def matches(self,thread,record,cwd):
        try:value=self.read(thread)
        except FileNotFoundError:return False
        return value['record']==record and value['cwd']==os.path.realpath(cwd)

    def model(self,thread,value=...):
        path=self.thread_path(thread).with_suffix('.model')
        if value is ...:
            try:raw=self.owner.private_file(path,4096)
            except FileNotFoundError:return None
            value=json.loads(raw)
        else:
            if value is not None and (not isinstance(value,str) or not 0<len(value)<=512):
                raise ValueError('invalid saved model selection')
            fd,name=tempfile.mkstemp(prefix='.model-',dir=path.parent)
            try:
                with os.fdopen(fd,'w') as stream:
                    json.dump(value,stream);stream.flush();os.fsync(stream.fileno())
                os.replace(name,path);self.owner.sync_directory(path.parent)
            finally:
                if os.path.exists(name):os.unlink(name)
        if value is not None and (not isinstance(value,str) or not 0<len(value)<=512):
            raise ValueError('invalid saved model selection')
        return value

    def home(self,record,cwd,config):
        key=hashlib.sha256(json.dumps([record,os.path.realpath(cwd)],sort_keys=True).encode()).hexdigest()
        home=self.base/'homes'/key
        self.owner.private_directory(home,create=True)
        # Prepare configuration independently, then replace only managed entries.
        # Session files and provider databases survive each process restart.
        with tempfile.TemporaryDirectory(prefix='.config-',dir=self.base) as directory:
            staged=Path(directory);runner.prepare_home(Path(config).resolve(strict=True),staged)
            for name in ('config.toml','AGENTS.md','AGENTS.override.md','managed_config.toml','rules','skills','plugins'):
                source=staged/name;destination=home/name
                if os.path.lexists(source):os.replace(source,destination)
                elif os.path.lexists(destination):destination.unlink()
        return str(home)


def session_rows(root,profile=None,identifier=None):
    base=Path(root)/'codex-sessions'
    if not os.path.lexists(base):return []
    sessions=Sessions(root);base=sessions.base
    metadata=client.load('n2_session_metadata','profile-metadata.py').report(root,None)['profiles']
    paths=[sessions.thread_path(identifier)] if identifier is not None else sorted((base/'threads').iterdir())
    rows=[]
    for path in paths:
        if identifier is None and not re.fullmatch('[0-9a-f]{64}',path.name):continue
        try:raw=sessions.owner.private_file(path,16384)
        except FileNotFoundError:continue
        saved=json.loads(raw,object_pairs_hook=sessions.owner.unique)
        thread=saved.get('thread') if isinstance(saved,dict) else None
        if sessions.thread_path(thread)!=path:raise ValueError('session index path mismatch')
        saved=sessions.read(thread)
        matches=[row for row in metadata if row['profileId']==saved['record']['profileId']]
        if len(matches)!=1 or matches[0]['metadataStatus']!='ready':
            raise ValueError('session profile identity is unavailable or ambiguous')
        name=matches[0]['name']
        if profile is not None and name!=profile:continue
        updated=path.stat().st_mtime
        model_path=path.with_suffix('.model')
        if os.path.lexists(model_path):
            sessions.model(thread);updated=max(updated,model_path.stat().st_mtime)
        clean=lambda value:re.sub(r'[\t\r\n]', ' ',value)
        rows.append([name,'codex',thread,str(int(updated)),clean(saved['cwd']),'','','Codex session'])
    return sorted(rows,key=lambda row:(-int(row[3]),row[2]))


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
    def __init__(self,journal,profile,account,sessions=None):
        self.journal=journal;self.profile=profile;self.account=account
        self.threads={};self.current=None;self.sessions=sessions

    def thread(self,identifier,model,fresh):
        requested=self.sessions.model(identifier) if self.sessions and not fresh else None
        self.threads[identifier]={'model':model,'requestedModel':requested,'total':dict.fromkeys(self.COUNTS,0) if fresh else None}

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
        if self.sessions:self.sessions.model(current['thread'],current['requestedModel'])
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
    def __init__(self,provider,emit,receipts=None,sessions=None,record=None):
        self.provider=provider;self.emit=emit;self.initialized=False;self.receipts=receipts
        self.sessions=sessions;self.record=record
        self.sequence=0;self.pending={};self.thread_requests={};self.approvals={};self.threads=set();self.active=False

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
        saved_thread=('threadId' in params and self.sessions
                      and self.sessions.matches(params['threadId'],self.record,self.provider.cwd))
        if method in ('thread/resume','thread/fork') and any(params.get(key) is not None for key in ('path','history')):
            self.error(message,'Resume requires a recorded N2 thread binding');return
        if 'threadId' in params and params['threadId'] not in self.threads and not saved_thread:
            self.error(message,'Thread has no account binding in this session');return
        if method.startswith(('thread/','turn/','review/')):
            overrides=params.get('config')
            safe_overrides=(overrides is None or (isinstance(overrides,dict) and all(
                key=='web_search' and isinstance(value,str) and value in ('disabled','cached','live')
                for key,value in overrides.items())))
            if params.get('modelProvider') not in (None,'openai') or not safe_overrides:
                self.error(message,'This session must keep its selected account route');return
        if method in ('turn/start','turn/steer','review/start'):
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
        if method in ('thread/start','thread/resume','thread/fork'):self.thread_requests[key]=params
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
            thread_params=self.thread_requests.pop(identifier,{})
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
                requested=thread_params.get('model')
                if self.sessions:
                    self.sessions.remember(thread['id'],self.record,self.provider.cwd)
                    if requested is None and request_method=='thread/fork':requested=self.sessions.model(thread_params['threadId'])
                    if requested is not None:self.sessions.model(thread['id'],requested)
                self.threads.add(thread['id'])
                if self.receipts:
                    self.receipts.thread(thread['id'],result.get('model'),request_method=='thread/start')
                    if requested is not None:self.receipts.threads[thread['id']]['requestedModel']=requested
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


def serve(provider,source,sink,receipts=None,sessions=None,record=None):
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
    bridge=Bridge(provider,emit,receipts,sessions,record);waiting=[];eof=False;last_progress=time.monotonic()
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


def terminal(provider,home,executable,arguments,receipts=None,sessions=None,record=None):
    # The directory restricts access to this user; there is no TCP listener or
    # bearer credential in command arguments, socket names or filesystem data.
    if any(arg=='--remote' or arg.startswith('--remote=') or arg.startswith('--remote-auth-token-env') for arg in arguments):
        raise ValueError('cannot override account-bound endpoint')
    with tempfile.TemporaryDirectory(prefix='n2-tui-',dir='/tmp') as directory:
        path=str(Path(directory)/'socket');listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        process=None;stream=None;connection=None;previous=signal.getsignal(signal.SIGINT)
        lifetime_writer=None
        try:
            listener.bind(path);os.chmod(path,0o600);listener.listen(1);listener.settimeout(.2)
            environment=client.native.environment(home);environment['CODEX_HOME']=home
            for key in ('TERM','COLORTERM','TERM_PROGRAM'):
                if key in os.environ:environment[key]=os.environ[key]
            lifetime_reader,lifetime_writer=os.pipe()
            try:
                process=subprocess.Popen(
                    [sys.executable,str(ROOT/'fleet-auth-bridge.py'),'--terminal-supervisor',
                     str(lifetime_reader),executable,'--remote','unix://'+path,*arguments],
                    env=environment,pass_fds=(lifetime_reader,))
            finally:
                os.close(lifetime_reader)
            signal.signal(signal.SIGINT,signal.SIG_IGN)
            deadline=time.monotonic()+15
            while True:
                if process.poll() is not None:raise RuntimeError('terminal did not connect')
                if time.monotonic()>=deadline:raise TimeoutError('terminal did not connect')
                try:connection,_=listener.accept();break
                except socket.timeout:continue
            listener.close()
            stream=load('n2_private_websocket','fleet-auth-websocket.py').Stream(connection)
            serve(provider,stream,stream,receipts,sessions,record)
            stream.close();return process.wait(timeout=5)
        finally:
            signal.signal(signal.SIGINT,previous);listener.close()
            if stream is not None:stream.close()
            elif connection is not None:connection.close()
            try:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:process.wait(timeout=3)
                    except subprocess.TimeoutExpired:process.kill();process.wait()
            finally:
                if lifetime_writer is not None:os.close(lifetime_writer)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',required=True);parser.add_argument('--profile')
    discovery=parser.add_mutually_exclusive_group()
    discovery.add_argument('--list-sessions',action='store_true');discovery.add_argument('--find-session')
    parser.add_argument('--config');parser.add_argument('--executable',default='codex')
    parser.add_argument('--tui',action='store_true');parser.add_argument('frontend_args',nargs=argparse.REMAINDER)
    args=parser.parse_args()
    def interrupted(*_):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupted)
    try:
        if args.list_sessions or args.find_session is not None:
            rows=session_rows(args.root,args.profile,args.find_session)
            if args.find_session is not None:
                if not rows:return 1
                print(rows[0][0])
            else:
                for row in rows:print('\t'.join(row))
            return 0
        if not args.config or not args.profile:raise ValueError('profile and config are required')
        broker=client.for_profile(args.root,args.config,args.profile)
        sessions=Sessions(args.root)
        arguments=args.frontend_args[1:] if args.frontend_args[:1]==['--'] else args.frontend_args
        cwd=os.getcwd()
        if args.tui and any(arg in ('resume','fork') for arg in arguments):
            if arguments[0] not in ('resume','fork') or (len(arguments)>1 and arguments[1].startswith('-')):
                raise ValueError('put resume or fork and the session ID before native options')
        # An explicit native resume selects the original grant before any token
        # request. It may fail if that grant was revoked, never use a replacement.
        if args.tui and len(arguments)>=2 and arguments[0] in ('resume','fork') and not arguments[1].startswith('-'):
            saved=sessions.read(arguments[1])
            if saved['record']['profileId']!=broker.record['profileId']:
                raise ValueError('session belongs to another profile')
            broker=client.OwnerClient(args.root,saved['record'],saved['record']['profileId'],saved['record']['accountHash'])
            cwd=saved['cwd']
            if not os.path.isdir(cwd):raise ValueError('session working directory unavailable')
            os.chdir(cwd)
        journal=runner.load('n2_bridge_journal','usage-store.py').Journal(args.root,broker.recipient)
        receipts=Receipts(journal,args.profile,broker.record['accountHash'],sessions)
        try:
            directory=sessions.home(broker.record,cwd,args.config)
            with broker.connection(directory,cwd,time.monotonic()+20,executable=args.executable) as (provider,_):
                if args.tui:
                    return terminal(provider,directory,args.executable,arguments,receipts,sessions,broker.record)
                if args.frontend_args:raise ValueError('unexpected app-server arguments')
                serve(provider,sys.stdin.buffer,sys.stdout.buffer,receipts,sessions,broker.record)
        finally:journal.db.close()
        return 0
    except (Exception,KeyboardInterrupt):
        print('agents: account-bound app-server unavailable',file=sys.stderr);return 2 if args.list_sessions or args.find_session is not None else 1

def terminal_supervisor():
    # Keep the native frontend in the terminal's process group. This supervisor
    # owns and reaps only its child; it must not signal the caller's whole group.
    if len(sys.argv)<4:raise SystemExit(2)
    descriptor=int(sys.argv[2]);os.fstat(descriptor)
    child=None;stopping=threading.Event()
    signal.signal(signal.SIGTERM,lambda *_:stopping.set())
    # A caught handler resets on exec; SIG_IGN would disable frontend Ctrl-C.
    signal.signal(signal.SIGINT,lambda *_:None)
    try:
        child=subprocess.Popen(sys.argv[3:],close_fds=True)
        while child.poll() is None:
            if stopping.is_set():
                child.terminate()
                try:return child.wait(timeout=2)
                except subprocess.TimeoutExpired:break
            if select.select([descriptor],[],[],.1)[0]:break
        if child.poll() is None:child.kill()
        return child.wait()
    finally:
        if child is not None and child.poll() is None:child.kill();child.wait()
        os.close(descriptor)


if __name__=='__main__':
    sys.exit(terminal_supervisor() if len(sys.argv)>1 and sys.argv[1]=='--terminal-supervisor' else main())
