#!/usr/bin/env python3
"""Local owner registration and consent. Never imports a legacy login grant."""
import argparse
import importlib.util
import json
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
    parser.add_argument('action',choices=('register','status','allow','deny','validate-incoming'))
    parser.add_argument('root');parser.add_argument('profile');parser.add_argument('config')
    parser.add_argument('--payload');parser.add_argument('--grant');parser.add_argument('--peer');parser.add_argument('--expected-revision')
    args=parser.parse_args()
    try:
        if args.action=='validate-incoming':
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
    except Exception:
        print('agents: owner registration unavailable; check profile identity, grant state, migration and conflicts',file=sys.stderr)
        return 1

if __name__=='__main__':sys.exit(main())
