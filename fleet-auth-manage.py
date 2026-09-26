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


def register(root,name,config,grant_id,expected_revision=None,login_operation=None):
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
        if login_operation is not None:
            peers=load('n2_remote_login','fleet-auth-login.py').publication_allowed(root,name,config,grant_id,expected_revision,login_operation)
            grant.state['allowedPeers']=sorted(set(peers));grant._save()
        revision=binding.publish(config,record,profile_id,expected_revision)
        return {'status':'registered','binding':record,'revision':revision}


def consent(root,name,config,peer,allowed,login_management=False):
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
                or public['ownershipGeneration']!=record['ownershipGeneration'] or public['state']=='retired' or (not login_management and public['state']!='active')):
            raise ValueError('registered grant is not active')
        if login_management:load('n2_remote_login','fleet-auth-login.py').permission(grant,peer,allowed)
        else:grant.consent(peer,allowed)
    return {'status':'allowed' if allowed else 'denied','peer':peer,'grantId':record['grantId']}


def status(root,name,config):
    root=Path(root).resolve(strict=True)
    migration=load('n2_migration','fleet-auth-migration.py').pending(root,name,config)
    if migration:
        return {'status':'migration-pending' if migration['state']=='pending' else 'migration-invalid',
                'binding':None,'revision':None}
    if binding.conflicted(root,name):
        return {'status':'conflicting','binding':None,'revision':None}
    record,revision=binding.read(config,profile(root,name))
    result={'binding':record,'revision':revision,'status':'remote-owner'}
    if record['owner']==identity(root):
        store=binding.owner.OwnerStore(root/'fleet/auth-owners',record['owner'])
        with store.locked(record['grantId'],time.monotonic()+2) as grant:
            public=grant.public()
            matches=all(public[k]==record[k] for k in ('profileId','accountHash','ownershipGeneration'))
            retired=(public['state']=='retired' and all(public[k]==record[k] for k in ('profileId','accountHash')))
            result['status']=public['state'] if matches or retired else 'binding-mismatch'
    return result


def reconcile(root,name,config):
    root=Path(root).resolve(strict=True)
    if binding.conflicted(root,name):raise ValueError('resolve ownership conflict first')
    record,revision=binding.read(config,profile(root,name));me=identity(root)
    if record['owner']!=me:raise ValueError('reconciliation belongs to the designated owner')
    store=binding.owner.OwnerStore(root/'fleet/auth-owners',me)
    with store.locked(record['grantId'],time.monotonic()+20) as grant:
        public=grant.public()
        if any(public[key]!=record[key] for key in ('profileId','accountHash','ownershipGeneration')):
            raise ValueError('owner binding changed')
        if public['state']!='renewing':raise ValueError('grant has no uncertain renewal to reconcile')
        server.native.NativeOwner().reconcile(grant)
    return {'status':'active','binding':record,'revision':revision}


def retire(root,name,grant_id):
    root=Path(root).resolve(strict=True);profile_id=profile(root,name);me=identity(root)
    store=binding.owner.OwnerStore(root/'fleet/auth-owners',me)
    with store.locked(grant_id,time.monotonic()+5) as grant:
        if grant.public()['profileId']!=profile_id:raise ValueError('grant belongs to another profile')
        grant.retire()
    return {'status':'retired','grantId':grant_id}


def inventory(root,name):
    root=Path(root).resolve(strict=True);profile_id=profile(root,name);me=identity(root)
    directory=root/'fleet/auth-owners';rows=[]
    if not directory.exists():return {'grants':rows}
    binding.owner.private_directory(directory)
    # Atomic private state snapshots are sufficient for diagnostics. Acquiring
    # the grant lock here would hide pending logins until human sign-in ends.
    for entry in sorted(directory.iterdir()):
        try:
            if not binding.owner.uuid_value(entry.name):continue
        except (ValueError,TypeError,AttributeError):continue
        try:
            binding.owner.private_directory(entry)
            state=json.loads(binding.owner.private_file(entry/'state.json',128*1024),object_pairs_hook=binding.owner.unique)
            binding.owner.validate(state)
            if state['grantId']!=entry.name or state['owner']!=me:raise ValueError('invalid owner state')
            if state['profileId']!=profile_id:continue
            rows.append({key:state[key] for key in ('grantId','profileId','owner','accountHash','state')})
        except (OSError,ValueError,TypeError):
            rows.append({'grantId':entry.name,'state':'invalid'})
    return {'grants':rows}


def login(root,name,config,expected_revision=None,replace_account=False,timeout=600):
    root=Path(root).resolve(strict=True);config=Path(config).resolve(strict=True)
    profile_id=profile(root,name)
    if binding.conflicted(root,name):raise ValueError('resolve ownership conflict first')
    binding.controlled_directory(config)
    if os.path.lexists(config/'.n2-migration.json'):raise ValueError('profile migration pending')
    for file in ('auth.json','.credentials.json','oauth_creds.json','credentials.json'):
        if os.path.lexists(config/file):raise ValueError('legacy credentials require migration')
    if type(timeout) not in (int,float) or not math.isfinite(timeout) or not 1<=timeout<=900:
        raise ValueError('invalid login deadline')
    me=identity(root);expected_account=None
    if os.path.lexists(config/binding.MARKER):
        previous,revision=binding.read(config,profile_id)
        if expected_revision!=revision:raise ValueError('replacement requires current revision')
        if previous['owner']!=me:
            return load('n2_remote_login','fleet-auth-login.py').client_login(root,name,config,previous,revision,replace_account,timeout)
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
    if os.path.lexists(config/'.n2-migration.json'):raise ValueError('profile migration pending')
    for file in ('auth.json','.credentials.json','oauth_creds.json','credentials.json'):
        if (config/file).exists() or (config/file).is_symlink():
            raise ValueError('legacy credentials require migration')
    if (config/binding.MARKER).exists() or (config/binding.MARKER).is_symlink():
        binding.read(config,profile_id)
    return {'status':'valid'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('register','status','allow','deny','login','reconcile','retire','grants','allow-login','deny-login','validate-incoming','migration-status','migration-begin','migration-abandon'))
    parser.add_argument('root');parser.add_argument('profile');parser.add_argument('config')
    parser.add_argument('--allow-legacy',action='store_true')
    parser.add_argument('--replace-account',action='store_true');parser.add_argument('--timeout',type=float,default=600)
    parser.add_argument('--login-operation');parser.add_argument('--expected-config');parser.add_argument('--payload');parser.add_argument('--grant');parser.add_argument('--peer');parser.add_argument('--expected-revision')
    args=parser.parse_args()
    try:
        if args.allow_legacy and args.action!='migration-abandon':raise ValueError('invalid legacy recovery option')
        if args.login_operation is not None and args.action!='register':raise ValueError('invalid operation option')
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
            result=register(args.root,args.profile,args.config,args.grant,args.expected_revision,args.login_operation)
        elif args.action=='migration-abandon':
            if args.grant or args.peer:raise ValueError('invalid migration options')
            result=load('n2_migration','fleet-auth-migration.py').abandon(args.root,args.profile,args.config,args.expected_revision,args.allow_legacy)
        elif args.action in ('migration-status','migration-begin'):
            if args.grant or args.peer or args.expected_revision:raise ValueError('invalid migration options')
            migration=load('n2_migration','fleet-auth-migration.py')
            result=(migration.begin if args.action=='migration-begin' else migration.inventory)(args.root,args.profile,args.config)
        elif args.action in ('reconcile','grants'):
            if args.grant or args.peer or args.expected_revision:raise ValueError('invalid recovery options')
            result=reconcile(args.root,args.profile,args.config) if args.action=='reconcile' else inventory(args.root,args.profile)
        elif args.action=='retire':
            if not args.grant or args.peer or args.expected_revision:raise ValueError('retire requires grant ID')
            result=retire(args.root,args.profile,args.grant)
        elif args.action=='status':
            if args.grant or args.peer or args.expected_revision:raise ValueError('invalid status options')
            result=status(args.root,args.profile,args.config)
        else:
            if not args.peer or args.grant or args.expected_revision:raise ValueError('consent requires peer')
            result=consent(args.root,args.profile,args.config,args.peer,args.action in ('allow','allow-login'),args.action in ('allow-login','deny-login'))
        print(json.dumps(result,sort_keys=True,separators=(',',':')))
        return 0
    except KeyboardInterrupt:
        print('agents: owner login interrupted; inspect profile status before retrying',file=sys.stderr)
        return 130
    except Exception:
        print('agents: owner registration unavailable; check profile identity, grant state, migration and conflicts',file=sys.stderr)
        return 1

if __name__=='__main__':sys.exit(main())
