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
         'plugin/list','app/list','mcpServerStatus/list','experimentalFeature/list','collaborationMode/list'}


def valid_id(value):
    return type(value) is int or (isinstance(value,str) and 0<len(value)<=256)


def decode(raw):
    if len(raw)>MAX_BYTES:raise ValueError('message too large')
    value=json.loads(raw,object_pairs_hook=client.binding.owner.unique,
                     parse_constant=lambda _: (_ for _ in ()).throw(ValueError('invalid number')))
    if not isinstance(value,dict):raise ValueError('invalid message')
    return value


class Bridge:
    def __init__(self,provider,emit):
        self.provider=provider;self.emit=emit;self.initialized=False
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
        if params.get('cwd') not in (None,self.provider.cwd):
            self.error(message,'Start a separate account-bound session for another working directory');return
        if 'threadId' in params and params['threadId'] not in self.threads:
            self.error(message,'Thread has no account binding in this session');return
        if method.startswith(('thread/','turn/','review/')):
            if params.get('modelProvider') not in (None,'openai') or params.get('config'):
                self.error(message,'This session must keep its selected account route');return
        if method in ('thread/resume','thread/fork','turn/start','turn/steer','review/start'):
            if params.get('threadId') not in self.threads:
                self.error(message,'Thread has no account binding in this session');return
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
        if method in ('turn/start','review/start'):self.active=True
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
            if request_method in ('turn/start','review/start') and 'error' in message:self.active=False
            if request_method in ('thread/start','thread/resume','thread/fork') and 'result' in message:
                result=message['result'];thread=result.get('thread') if isinstance(result,dict) else None
                if (not isinstance(thread,dict) or not isinstance(thread.get('id'),str) or not thread['id']
                        or result.get('modelProvider')!='openai' or result.get('cwd')!=self.provider.cwd):
                    raise RuntimeError('thread route does not match selected account')
                self.threads.add(thread['id'])
            self.emit(dict(message,id=frontend_id));return
        if not isinstance(method,str):raise ValueError('invalid provider method')
        if method=='turn/completed':self.active=False
        if 'id' in message:
            if not valid_id(identifier) or len(self.approvals)>=128:raise ValueError('invalid approval request')
            key=self.key();self.approvals[key]=identifier;message=dict(message,id=key)
        self.emit(message)


def serve(provider,source,sink):
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
    bridge=Bridge(provider,emit);waiting=[];eof=False;last_progress=time.monotonic()
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
            if waiting and not bridge.pending:
                bridge.frontend(waiting.pop(0));last_progress=time.monotonic()
            if eof and not waiting and not bridge.pending:return
            if (waiting or bridge.pending) and time.monotonic()-last_progress>120:
                raise TimeoutError('frontend request timed out')
    finally:stopped.set()


def terminal(provider,home,executable,arguments):
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
            serve(provider,stream,stream)
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
        with tempfile.TemporaryDirectory(prefix='n2-owner-session-') as directory:
            runner.prepare_home(Path(args.config).resolve(strict=True),Path(directory))
            with broker.connection(directory,os.getcwd(),time.monotonic()+20,executable=args.executable) as (provider,_):
                if args.tui:
                    arguments=args.frontend_args[1:] if args.frontend_args[:1]==['--'] else args.frontend_args
                    return terminal(provider,directory,args.executable,arguments)
                if args.frontend_args:raise ValueError('unexpected app-server arguments')
                serve(provider,sys.stdin.buffer,sys.stdout.buffer)
        return 0
    except (Exception,KeyboardInterrupt):
        print('agents: account-bound app-server unavailable',file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
