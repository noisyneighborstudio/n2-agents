#!/usr/bin/env python3
"""Read-only migration inventory and an explicit local migration barrier.

No credentials are opened, exported, moved, deleted or fingerprinted here.
An inventory is evidence of known copies, never proof that other copies do not exist.
"""
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import time
import uuid

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('n2_migration_manage',ROOT/'fleet-auth-manage.py')
manage=importlib.util.module_from_spec(spec);spec.loader.exec_module(manage)
MARKER='.n2-migration.json'
FILES=('auth.json','.credentials.json','oauth_creds.json','credentials.json')
MAX_ENTRIES=4096


def kind(path):
    try:
        mode=path.lstat().st_mode
        return 'symlink' if stat.S_ISLNK(mode) else 'file' if stat.S_ISREG(mode) else 'other'
    except FileNotFoundError:return 'absent'
    except OSError:return 'unavailable'


def metadata(path):
    raw=manage.server.transport.bounded_file(path,65536)
    result={}
    for line in raw.decode().splitlines():
        key,sep,value=line.partition('=')
        if not sep or key in result:raise ValueError('invalid metadata')
        result[key]=value
    return result


def entries(directory):
    # Never follow a directory symlink while inspecting fleet-local evidence.
    if kind(directory)=='absent':return []
    if directory.is_symlink() or not directory.is_dir():raise ValueError('invalid inventory directory')
    with os.scandir(directory) as iterator:
        result=[]
        for entry in iterator:
            if len(result)>=MAX_ENTRIES:raise ValueError('inventory limit exceeded')
            result.append(Path(entry.path))
    return sorted(result)


def pending(root,name,config):
    if not os.path.lexists(Path(config)/MARKER):return None
    try:
        value=json.loads(manage.binding.owner.private_file(Path(config)/MARKER,4096),
                         object_pairs_hook=manage.binding.owner.unique)
        if (not isinstance(value,dict) or set(value)!={'schemaVersion','migrationId','profileId','machine','startedAt','state'}
                or type(value['schemaVersion']) is not int or value['schemaVersion']!=1
                or not manage.binding.owner.uuid_value(value['migrationId'])
                or value['profileId']!=manage.profile(root,name)
                or not manage.binding.owner.peer_value(value['machine'])
                or type(value['startedAt']) is not int or value['startedAt']<0
                or value['state']!='pending'):raise ValueError('invalid migration state')
        return value
    except (OSError,ValueError,TypeError):return {'state':'invalid'}


def inventory(root,name,config):
    root=Path(root).resolve(strict=True);config=Path(config).resolve(strict=True)
    profile_id=manage.profile(root,name);me=manage.identity(root)
    files=[{'name':name,'state':kind(config/name)} for name in FILES]
    peers=[];copies=[];unknown=[]
    try:
        for path in entries(root/'fleet/peers'):
            try:
                if path.is_symlink() or not path.is_dir():raise ValueError('invalid inventory entry')
                info=metadata(path/'meta');peer=info.get('peer')
                if not manage.binding.owner.peer_value(peer):raise ValueError('invalid peer')
                if peer==me:continue
                state=info.get('state')
                peers.append({'peer':peer,'approval':state if state in ('approved','pending','revoked','denied') else 'unknown',
                              'credentialCopies':'unobserved','retirement':'unconfirmed'})
            except (OSError,ValueError,TypeError):unknown.append('peer-metadata-unavailable')
    except (OSError,ValueError):unknown.append('peer-inventory-incomplete')
    try:
        for path in entries(root/'fleet/sync/conflicts'):
            try:
                if path.is_symlink() or not path.is_dir():raise ValueError('invalid inventory entry')
                info=metadata(path/'meta');address=info.get('addr','').split('|')
                if len(address)!=4:raise ValueError('invalid address')
                category,profile,vendor,relative=address
                if profile!=name or vendor!='codex' or category not in ('auth','settings','mcp'):continue
                # The relative resource name and content are deliberately omitted.
                # Settings/MCP snapshots may embed credentials; do not infer absence.
                copies.append({'category':category,'local':kind(path/'local'),'remote':kind(path/'remote'),
                               'credentialContent':'not-inspected'})
            except (OSError,ValueError,TypeError):unknown.append('conflict-metadata-unavailable')
    except (OSError,ValueError):unknown.append('conflict-inventory-incomplete')
    migration=pending(root,name,config)
    return {'schemaVersion':1,'profileId':profile_id,'machine':me,'observedAt':int(time.time()),
            'status':'migration-pending' if migration and migration['state']=='pending' else 'migration-invalid' if migration else 'inventory-only',
            'migration':migration,'credentialFiles':files,'retainedSyncCopies':copies,'peers':peers,
            'keychain':'not-inspected','embeddedCredentials':'not-inspected','unmanagedProcesses':'unknown',
            'providerRevocation':'unconfirmed','inventoryScope':'top-level-credential-files-and-sync-conflicts','inventoryComplete':False,'unknowns':sorted(set(unknown))}


def begin(root,name,config):
    # Caller holds the same profile/slot locks as registration and sync writes.
    root=Path(root).resolve(strict=True);config=Path(config).resolve(strict=True)
    manage.binding.controlled_directory(config)
    current=pending(root,name,config)
    if current:
        if current['state']!='pending':raise ValueError('invalid migration requires repair')
        return inventory(root,name,config)
    if manage.binding.has_intent(root,name,config):raise ValueError('profile already has owner intent')
    value={'schemaVersion':1,'migrationId':str(uuid.uuid4()),'profileId':manage.profile(root,name),
           'machine':manage.identity(root),'startedAt':int(time.time()),'state':'pending'}
    fd,temporary=tempfile.mkstemp(prefix='.n2-migration-',dir=config)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write(json.dumps(value,sort_keys=True,separators=(',',':')).encode()+b'\n');out.flush();os.fsync(out.fileno())
        os.replace(temporary,config/MARKER);manage.binding.owner.sync_directory(config)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)
    return inventory(root,name,config)
