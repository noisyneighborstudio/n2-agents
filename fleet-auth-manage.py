#!/usr/bin/env python3
"""Local owner registration and consent. Never imports a legacy login grant."""
import argparse
import importlib.util
import json
import os
import math
import subprocess
import signal
from pathlib import Path
import sys
import time

ROOT=Path(__file__).resolve().parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

binding=load('n2_manage_binding','fleet-auth-binding.py')
metadata=load('n2_manage_metadata','profile-metadata.py')
server=load('n2_manage_server','fleet-auth-server.py')


def profile(root,name):
    rows=[row for row in metadata.report(root,None)['profiles'] if row['name']==name]
    if len(rows)!=1 or rows[0]['metadataStatus']!='ready':
        raise ValueError('profile requires ready unique metadata')
    return rows[0]['profileId']


def identity(root):
    return server.codec.public_identity(server.transport.bounded_file(root/'fleet/identity/id_ed25519.pub',1024))[0]


def register(root,name,config,grant_id,expected_revision=None):
    """Caller holds the profile marker and ownership-record sync resource locks."""
    root=Path(root).resolve(strict=True);config=Path(config)
    profile_id=profile(root,name)
    # Initial adoption with legacy credentials requires migration, not an
    # assertion that copying the public record made old copies safe.
    for file in ('auth.json','.credentials.json','oauth_creds.json','credentials.json'):
        if (config/file).exists() or (config/file).is_symlink():
            raise ValueError('legacy credentials require migration before registration')
    me=identity(root)
    store=binding.owner.OwnerStore(root/'fleet/auth-owners',me)
    with store.locked(grant_id,time.monotonic()+5) as grant:
        record=binding.from_grant(grant,profile_id)
        # Pending sync conflicts are never silently resolved by registration.
        if binding.conflicted(root,name):
            raise ValueError('ownership record has an unresolved sync conflict')
        revision=binding.publish(config,record,profile_id,expected_revision)
        return {'status':'registered','binding':record,'revision':revision}


def consent(root,name,config,peer,allowed):
    root=Path(root).resolve(strict=True)
    if binding.conflicted(root,name):
        raise ValueError('resolve ownership conflict before changing consent')
    record,_=binding.read(config,profile(root,name))
    me=identity(root)
    if record['owner']!=me:
        raise ValueError('consent must be changed at the grant owner')
    if allowed:server.approved(root,peer)
    store=binding.owner.OwnerStore(root/'fleet/auth-owners',me)
    with store.locked(record['grantId'],time.monotonic()+5) as grant:
        public=grant.public()
        if (public['profileId']!=record['profileId'] or public['accountHash']!=record['accountHash']
                or public['ownershipGeneration']!=record['ownershipGeneration'] or public['state']!='active'):
            raise ValueError('registered grant is not active')
        grant.consent(peer,allowed)
    return {'status':'allowed' if allowed else 'denied','peer':peer,'grantId':record['grantId']}


def status(root,name,config):
    root=Path(root).resolve(strict=True)
    if binding.conflicted(root,name):
        return {'status':'conflicting','binding':None,'revision':None}
    record,revision=binding.read(config,profile(root,name))
    result={'binding':record,'revision':revision,'status':'remote-owner'}
    if record['owner']==identity(root):
        store=binding.owner.OwnerStore(root/'fleet/auth-owners',record['owner'])
        with store.locked(record['grantId'],time.monotonic()+2) as grant:
            public=grant.public()
            matches=all(public[k]==record[k] for k in ('profileId','accountHash','ownershipGeneration'))
            result['status']=public['state'] if matches else 'binding-mismatch'
    return result


def login(root,name,config,expected_revision=None,replace_account=False,timeout=600):
    root=Path(root).resolve(strict=True);config=Path(config).resolve(strict=True)
    profile_id=profile(root,name)
    if binding.conflicted(root,name):raise ValueError('resolve ownership conflict first')
    binding.controlled_directory(config)
    for file in ('auth.json','.credentials.json','oauth_creds.json','credentials.json'):
        if os.path.lexists(config/file):raise ValueError('legacy credentials require migration')
    if type(timeout) not in (int,float) or not math.isfinite(timeout) or not 1<=timeout<=900:
        raise ValueError('invalid login deadline')
    me=identity(root);expected_account=None
    if os.path.lexists(config/binding.MARKER):
        previous,revision=binding.read(config,profile_id)
        if previous['owner']!=me:raise ValueError('login must run at the existing owner')
        if expected_revision!=revision:raise ValueError('replacement requires current revision')
        if not replace_account:expected_account=previous['accountHash']
    elif expected_revision is not None or replace_account:
        raise ValueError('replacement requires existing binding')
    store=binding.owner.OwnerStore(root/'fleet/auth-owners',me)
    created=store.create(profile_id,expected_account);grant_id=created['grantId']
    def challenge(value):
        print(json.dumps({'status':'login-required','grantId':grant_id,'owner':me,'challenge':value},
                         sort_keys=True,separators=(',',':')),flush=True)
    with store.locked(grant_id,time.monotonic()+timeout) as grant:
        server.native.NativeOwner().login(grant,challenge)
    # Human interaction holds only the fresh grant lock. Publication acquires
    # the normal metadata/resource/slot locks and compares the original intent.
    command=[str(ROOT/'agents'),'fleet','auth','register',name,'--grant',grant_id,
             '--expected-config',str(config)]
    if expected_revision is not None:command.extend(['--expected-revision',expected_revision])
    process=subprocess.Popen(command,env=dict(os.environ,N2_AGENTS_ROOT=str(root)),
                             stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
    try:
        output,_=process.communicate(timeout=75)
        if process.returncode!=0:raise ValueError('login verified but binding changed before publication')
    finally:
        # The shell may be waiting on a slot gate through descendants. Cancel
        # the entire group before acknowledging interruption; no delayed write
        # may survive the command. A completed publication is not rolled back.
        try:os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        process.wait(timeout=3)
        if process.stdout is not None:process.stdout.close()
    value=json.loads(output)
    if value.get('binding',{}).get('grantId')!=grant_id:raise ValueError('unexpected registration response')
    return value


def validate_incoming(root,name,config,payload):
    """Called under the resource and slot locks; no grant or credential import."""
    profile_id=profile(Path(root),name)
    raw=server.transport.bounded_file(Path(payload),binding.MAX_BYTES)
    record=json.loads(raw,object_pairs_hook=binding.owner.unique)
    binding.validate(record,profile_id)
    config=Path(config)
    if config.exists():
        binding.controlled_directory(config)
    for file in ('auth.json','.credentials.json','oauth_creds.json','credentials.json'):
        if (config/file).exists() or (config/file).is_symlink():
            raise ValueError('legacy credentials require migration')
    if (config/binding.MARKER).exists() or (config/binding.MARKER).is_symlink():
        binding.read(config,profile_id)
    return {'status':'valid'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('register','status','allow','deny','login','validate-incoming'))
    parser.add_argument('root');parser.add_argument('profile');parser.add_argument('config')
    parser.add_argument('--replace-account',action='store_true');parser.add_argument('--timeout',type=float,default=600)
    parser.add_argument('--expected-config');parser.add_argument('--payload');parser.add_argument('--grant');parser.add_argument('--peer');parser.add_argument('--expected-revision')
    args=parser.parse_args()
    try:
        if args.expected_config is not None and (args.action!='register' or str(Path(args.config).resolve(strict=True))!=args.expected_config):
            raise ValueError('profile route changed')
        if args.action!='login' and (args.replace_account or args.timeout!=600):raise ValueError('invalid login options')
        if args.action=='login':
            def interrupted(signum,frame):raise KeyboardInterrupt()
            signal.signal(signal.SIGTERM,interrupted)
            if args.grant or args.peer or args.payload:raise ValueError('invalid login options')
            result=login(args.root,args.profile,args.config,args.expected_revision,args.replace_account,args.timeout)
        elif args.action=='validate-incoming':
            if not args.payload or args.grant or args.peer or args.expected_revision:raise ValueError('invalid payload options')
            result=validate_incoming(args.root,args.profile,args.config,args.payload)
        elif args.payload:raise ValueError('unexpected payload')
        elif args.action=='register':
            if not args.grant or args.peer:raise ValueError('register requires grant')
            result=register(args.root,args.profile,args.config,args.grant,args.expected_revision)
        elif args.action=='status':
            if args.grant or args.peer or args.expected_revision:raise ValueError('invalid status options')
            result=status(args.root,args.profile,args.config)
        else:
            if not args.peer or args.grant or args.expected_revision:raise ValueError('consent requires peer')
            result=consent(args.root,args.profile,args.config,args.peer,args.action=='allow')
        print(json.dumps(result,sort_keys=True,separators=(',',':')))
        return 0
    except KeyboardInterrupt:
        print('agents: owner login interrupted; inspect profile status before retrying',file=sys.stderr)
        return 130
    except Exception:
        print('agents: owner registration unavailable; check profile identity, grant state, migration and conflicts',file=sys.stderr)
        return 1

if __name__=='__main__':sys.exit(main())
