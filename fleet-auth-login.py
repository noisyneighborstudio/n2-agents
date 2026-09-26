#!/usr/bin/env python3
"""Owner-side, requester-bound device login operations. No refresh grants on wire."""
import contextlib
import fcntl
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import stat
import sys
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

manage=load('n2_login_manage','fleet-auth-manage.py')
wire=load('n2_login_wire','fleet-auth-login-wire.py')
owner=manage.binding.owner
TERMINAL={'completed','cancelled','failed'}
INTENT=wire.FIELDS-{'nonce','expiresAt','action'}


def atomic(path,value):
    owner.private_directory(path.parent)
    fd,tmp=tempfile.mkstemp(prefix='.login-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write(wire.codec.canonical(value));out.flush();os.fsync(out.fileno())
        os.replace(tmp,path);owner.sync_directory(path.parent)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)


def permission(grant,peer,allowed=None):
    path=grant.directory/'login-peers.json';public=grant.public()
    try:
        value=wire.codec.decode_json(owner.private_file(path,65536))
        if (not isinstance(value,dict) or set(value)!={'schemaVersion','ownershipGeneration','peers'}
                or type(value['schemaVersion']) is not int or value['schemaVersion']!=1
                or value['ownershipGeneration']!=public['ownershipGeneration']
                or not isinstance(value['peers'],list) or len(value['peers'])>1024
                or any(not owner.peer_value(p) for p in value['peers'])
                or value['peers']!=sorted(set(value['peers']))):raise ValueError('invalid management consent')
    except FileNotFoundError:
        value={'schemaVersion':1,'ownershipGeneration':public['ownershipGeneration'],'peers':[]}
    if public['state']=='retired':raise ValueError('grant retired')
    if allowed is None:return peer in value['peers']
    if not owner.peer_value(peer) or type(allowed) is not bool:raise ValueError('invalid peer')
    peers=set(value['peers'])
    if allowed:peers.add(peer)
    else:peers.discard(peer)
    if len(peers)>1024:raise ValueError('too many management peers')
    value['peers']=sorted(peers);atomic(path,value)


class Operations:
    def __init__(self,root):
        self.root=Path(root).resolve(strict=True);self.me=manage.identity(self.root)
        self.directory=self.root/'fleet/auth-logins';owner.private_directory(self.directory,create=True)
        owner.sync_directory(self.directory.parent)
        self.store=owner.OwnerStore(self.root/'fleet/auth-owners',self.me)

    def path(self,operation):
        if not owner.uuid_value(operation):raise ValueError('invalid operation')
        return self.directory/operation

    @contextlib.contextmanager
    def lock(self,operation,seconds=2):
        directory=self.path(operation);owner.private_directory(directory,create=True)
        fd=os.open(directory/'lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
        try:
            info=os.fstat(fd)
            import stat
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o077 or info.st_nlink!=1:
                raise ValueError('invalid operation lock')
            deadline=time.monotonic()+seconds
            while True:
                try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);break
                except BlockingIOError:
                    if time.monotonic()>=deadline:raise TimeoutError('operation busy')
                    time.sleep(.02)
            yield fd
        finally:os.close(fd)

    def read(self,operation):
        row=wire.codec.decode_json(owner.private_file(self.path(operation)/'state.json',65536))
        if (not isinstance(row,dict) or set(row)!={'intent','name','config','grant','created','deadline','status','challenge','binding'}
                or not isinstance(row['intent'],dict) or set(row['intent'])!=INTENT
                or row['status'] not in wire.STATES-{'busy'}
                or row['intent']['operationId']!=operation or row['intent']['owner']!=self.me
                or not isinstance(row['name'],str) or not isinstance(row['config'],str)
                or not owner.uuid_value(row['grant']) or type(row['created']) not in (int,float)
                or type(row['deadline']) not in (int,float) or not math.isfinite(row['created'])
                or not math.isfinite(row['deadline']) or not 0<row['deadline']-row['created']<=900):
            raise ValueError('invalid operation state')
        context=dict(row['intent'],action='status',nonce='0'*64,expiresAt=time.time()+10)
        wire.validate_context(context);wire.validate_result(self.result(row),context)
        return row

    def save(self,row):atomic(self.path(row['intent']['operationId'])/'state.json',row)
    def result(self,row):return {key:row[key] for key in ('status','challenge','binding')}

    def authorize(self,intent):
        if intent['owner']!=self.me or manage.identity(self.root)!=self.me:raise ValueError('wrong owner')
        manage.server.approved(self.root,intent['recipient'])
        with self.store.locked(intent['grantId'],time.monotonic()+2) as grant:
            public=grant.public()
            if any(public[key]!=intent[key] for key in ('profileId','ownershipGeneration','accountHash')):
                raise ValueError('management binding changed')
            if not permission(grant,intent['recipient']):raise ValueError('management consent required')
            return list(grant.state['allowedPeers'])

    def await_authorization(self,row):
        # Renewal holds the same grant lock. Contention is not revocation.
        while time.time()<row['deadline']:
            try:
                with self.lock(row['intent']['operationId']):
                    if self.read(row['intent']['operationId'])['status'] in TERMINAL:
                        raise ValueError('login stopped')
                return self.authorize(row['intent'])
            except TimeoutError:continue
        raise ValueError('login expired')

    def route(self,intent):
        rows=[row for row in manage.metadata.report(self.root,None)['profiles']
              if row['profileId']==intent['profileId'] and row['metadataStatus']=='ready']
        if len(rows)!=1:raise ValueError('profile unavailable')
        name=rows[0]['name'];routes=manage.metadata.routing_inventory(self.root)[1]
        config=Path(routes[(name,'codex')]['configDir']).resolve(strict=True)
        if manage.binding.conflicted(self.root,name):raise ValueError('ownership conflict')
        record,revision=manage.binding.read(config,intent['profileId'])
        if revision!=intent['bindingRevision'] or any(record[key]!=intent[key] for key in
                ('owner','profileId','grantId','ownershipGeneration','accountHash')):
            raise ValueError('profile binding changed')
        return name,str(config)

    def update(self,operation,status,challenge=None):
        with self.lock(operation):
            row=self.read(operation)
            if row['status'] in TERMINAL:return False
            row.update(status=status,challenge=challenge,binding=None);self.save(row);return True

    def start(self,context):
        intent={key:context[key] for key in INTENT};self.authorize(intent)
        with self.lock(intent['operationId']):
            try:
                row=self.read(intent['operationId'])
                if row['intent']!=intent:raise ValueError('operation intent changed')
                return self.result(row)
            except FileNotFoundError:pass
            name,config=self.route(intent)
            grant=self.store.create(intent['profileId'],None if intent['replaceAccount'] else intent['accountHash'])
            now=time.time();row={'intent':intent,'name':name,'config':config,'grant':grant['grantId'],
                'created':now,'deadline':now+600,'status':'starting','challenge':None,'binding':None}
            self.save(row);owner.sync_directory(self.directory)
            subprocess.Popen([sys.executable,str(ROOT/'fleet-auth-login.py'),'worker',str(self.root),intent['operationId']],
                stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,close_fds=True)
            return self.result(row)

    def worker(self,operation):
        # A separate run lock prevents duplicate native login after repeated start.
        directory=self.path(operation);owner.private_directory(directory)
        fd=os.open(directory/'run.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o077 or info.st_nlink!=1:
                raise ValueError('invalid worker lock')
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.lock(operation):row=self.read(operation)
            if row['status']!='starting':return
            self.await_authorization(row)
            stop=threading.Event()
            def interrupt(*_):raise KeyboardInterrupt()
            signal.signal(signal.SIGTERM,interrupt)
            def monitor():
                while not stop.wait(.25):
                    try:
                        if time.time()>=row['deadline']:raise ValueError('expired')
                        with self.lock(operation):current=self.read(operation)
                        if current['status'] in TERMINAL:raise ValueError('stopped')
                        self.authorize(row['intent'])
                    except TimeoutError:continue
                    except Exception:
                        os.kill(os.getpid(),signal.SIGTERM);return
            watcher=threading.Thread(target=monitor,daemon=True);watcher.start()
            try:
                deadline=time.monotonic()+max(0,row['deadline']-time.time())
                with self.store.locked(row['grant'],deadline) as grant:
                    def challenge(value):
                        if not self.update(operation,'login-required',value):raise KeyboardInterrupt()
                    manage.server.native.NativeOwner().login(grant,challenge)
                self.await_authorization(row);self.update(operation,'verified')
            except BaseException:
                self.update(operation,'failed')
            finally:stop.set();watcher.join(timeout=3)
        finally:os.close(fd)

    def published(self,row):
        try:
            record,_=manage.binding.read(row['config'],row['intent']['profileId'])
            if record['grantId']!=row['grant']:return False
            wire.validate_result({'status':'completed','challenge':None,'binding':record},
                dict(row['intent'],action='finish',nonce='0'*64,expiresAt=time.time()+10))
            row.update(status='completed',challenge=None,binding=record);self.save(row);return True
        except (OSError,ValueError):return False

    def finish(self,context):
        intent={key:context[key] for key in INTENT};self.authorize(intent)
        with self.lock(intent['operationId']) as fd:
            row=self.read(intent['operationId'])
            if row['intent']!=intent:raise ValueError('operation intent changed')
            if row['status']=='completed':return self.result(row)
            if row['status']!='verified':raise ValueError('login is not verified')
            if self.published(row):return self.result(row)
            if time.time()>=row['deadline']:raise ValueError('login expired')
            name,config=self.route(intent)
            if (name,config)!=(row['name'],row['config']):raise ValueError('profile route changed')
            deadline=time.monotonic()+8
            command=[sys.executable,str(ROOT/'codex-rpc.py'),'--lock-supervisor',str(fd),str(deadline),
                str(ROOT/'agents'),'fleet','auth','register',name,'--grant',row['grant'],
                '--expected-revision',intent['bindingRevision'],'--expected-config',config,
                '--login-operation',intent['operationId']]
            process=subprocess.Popen(command,env=dict(os.environ,N2_AGENTS_ROOT=str(self.root)),
                stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                start_new_session=True,pass_fds=(fd,))
            try:process.wait(timeout=9)
            finally:
                try:os.killpg(process.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                process.wait(timeout=2)
            # The supervisor deliberately kills its group on child completion;
            # inspect the durable binding instead of treating its exit as success.
            if not self.published(row):raise ValueError('publication did not complete')
            return self.result(row)

    def worker_alive(self,operation):
        try:fd=os.open(self.path(operation)/'run.lock',os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        except FileNotFoundError:return False
        try:
            try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);return False
            except BlockingIOError:return True
        finally:os.close(fd)

    def current(self,context):
        intent={key:context[key] for key in INTENT};self.authorize(intent)
        with self.lock(intent['operationId']):
            row=self.read(intent['operationId'])
            if row['intent']!=intent:raise ValueError('operation intent changed')
            if row['status']=='verified' and self.published(row):return self.result(row)
            if context['action']=='cancel' and row['status'] not in TERMINAL:
                row.update(status='cancelled',challenge=None,binding=None);self.save(row)
            elif row['status'] not in TERMINAL and (time.time()>=row['deadline'] or
                    (row['status'] in ('starting','login-required','verifying') and time.time()-row['created']>5
                     and not self.worker_alive(intent['operationId']))):
                row.update(status='failed',challenge=None,binding=None);self.save(row)
            return self.result(row)


def publication_allowed(root,name,config,grant_id,revision,operation):
    # The caller holds the normal profile/resource/slot locks. The finish
    # supervisor retains the operation flock until the whole writer group exits.
    operations=Operations(root);row=operations.read(operation)
    if (row['status']!='verified' or row['grant']!=grant_id or row['name']!=name
            or row['config']!=str(Path(config).resolve(strict=True))
            or row['intent']['bindingRevision']!=revision or time.time()>=row['deadline']):
        raise ValueError('login operation cannot publish')
    peers=operations.authorize(row['intent'])
    # Existing access applies to the same authenticated account. Explicit
    # account changes start owner-only and need fresh sharing consent.
    return peers if not row['intent']['replaceAccount'] else [operations.me]


def response(root,sender,request):
    try:
        context=wire.codec.decode_json(manage.server.transport.bounded_file(request,4096))
        wire.validate_context(context)
        if context['recipient']!=sender:raise ValueError('wrong requester')
        operations=Operations(root)
        try:
            if context['action']=='start':result=operations.start(context)
            elif context['action']=='finish':result=operations.finish(context)
            else:result=operations.current(context)
        except TimeoutError:
            result={'status':'busy','challenge':None,'binding':None}
        manage.server.approved(operations.root,sender)
        return wire.sign(context,result,operations.root/'fleet/identity/id_ed25519',
                         time.monotonic()+min(3,context['expiresAt']-time.time()))
    except Exception:raise ValueError('remote login unavailable') from None


def client_login(root,name,config,record,revision,replace_account,timeout):
    import secrets
    root=Path(root).resolve(strict=True)
    peer=record['owner'];slug=peer.replace('/','_').replace('+','_').replace(':','_')
    public=manage.server.transport.bounded_file(root/'fleet/peers'/slug/'key.pub',1024)
    context={key:record[key] for key in ('owner','profileId','grantId','ownershipGeneration','accountHash')}
    import uuid
    context.update(schemaVersion=1,recipient=manage.identity(root),operationId=str(uuid.uuid4()),
                   bindingRevision=revision,replaceAccount=replace_account)
    deadline=time.monotonic()+timeout;complete=False;shown=None
    def call(action,limit=None):
        call_deadline=deadline if limit is None else time.monotonic()+limit
        while True:
            end=min(call_deadline,time.monotonic()+15)
            remaining=end-time.monotonic()
            if remaining<=0:raise TimeoutError('remote login expired')
            request=dict(context,action=action,nonce=secrets.token_hex(32),expiresAt=time.time()+min(20,remaining))
            result=manage.server.transport.exchange(root,request,public,end,protocol='login')
            if result['status']!='busy':return result
            time.sleep(min(.25,max(0,call_deadline-time.monotonic())))
    try:
        result=call('start')
        while True:
            state=result['status']
            if state=='login-required' and result['challenge']!=shown:
                shown=result['challenge']
                print(json.dumps({'status':'login-required','owner':peer,'operationId':context['operationId'],
                                  'challenge':shown},sort_keys=True,separators=(',',':')),flush=True)
            if state=='verified':result=call('finish');continue
            if state=='completed':
                complete=True;replacement=result['binding']
                # Use ordinary sync/conflict policy to update the requesting
                # machine. Completion at the owner is distinct from local parity.
                command=[str(ROOT/'agents'),'fleet','sync','now','--peer',peer]
                local=None;local_revision=None
                try:
                    subprocess.run(command,env=dict(os.environ,N2_AGENTS_ROOT=str(root)),stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
                    if not manage.binding.conflicted(root,name):
                        local,local_revision=manage.binding.read(config,record['profileId'])
                except (OSError,ValueError,subprocess.TimeoutExpired):pass
                return {'status':'registered' if local==replacement else 'owner-completed',
                        'binding':replacement,'revision':local_revision if local==replacement else None,
                        'localBinding':'current' if local==replacement else 'pending-sync'}
            if state in ('cancelled','failed'):raise ValueError('remote login did not complete')
            time.sleep(min(.25,max(0,deadline-time.monotonic())));result=call('status')
    finally:
        if not complete:
            try:call('cancel',limit=3)
            except Exception:pass


def main():
    try:
        if len(sys.argv)==4 and sys.argv[1]=='worker':
            Operations(sys.argv[2]).worker(sys.argv[3]);return 0
        if len(sys.argv)==5 and sys.argv[1]=='serve' and os.environ.get('SSH_CONNECTION'):
            sys.stdout.buffer.write(response(*sys.argv[2:]));sys.stdout.buffer.flush();return 0
        raise ValueError('invalid arguments')
    except BaseException:return 1

if __name__=='__main__':sys.exit(main())
