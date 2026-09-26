#!/usr/bin/env python3
"""Read-only migration inventory and an explicit local migration barrier.

No credentials are opened, exported, moved, deleted or fingerprinted here.
An inventory is evidence of known copies, never proof that other copies do not exist.
"""
import importlib.util
import hashlib
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


def validate_marker(value,profile_id):
    if (not isinstance(value,dict) or set(value)!={'schemaVersion','migrationId','profileId','machine','startedAt','state'}
                or type(value['schemaVersion']) is not int or value['schemaVersion']!=1
                or not manage.binding.owner.uuid_value(value['migrationId'])
                or value['profileId']!=profile_id
                or not manage.binding.owner.peer_value(value['machine'])
                or type(value['startedAt']) is not int or value['startedAt']<0
                or value['state']!='pending'):raise ValueError('invalid migration state')


def pending(root,name,config):
    if not os.path.lexists(Path(config)/MARKER):return None
    try:
        value=json.loads(manage.binding.owner.private_file(Path(config)/MARKER,4096),
                         object_pairs_hook=manage.binding.owner.unique)
        validate_marker(value,manage.profile(root,name))
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
    revision=None
    if migration and migration['state']=='pending':
        revision=hashlib.sha256(manage.binding.owner.private_file(config/MARKER,4096)).hexdigest()
    for row in peers:
        row['migrationBarrier']='prepared' if revision and acknowledged(root,revision,row['peer'],migration) else 'unacknowledged'
    return {'schemaVersion':1,'profileId':profile_id,'machine':me,'observedAt':int(time.time()),
            'status':'migration-pending' if migration and migration['state']=='pending' else 'migration-invalid' if migration else 'inventory-only',
            'migration':migration,'migrationRevision':revision,'credentialFiles':files,'retainedSyncCopies':copies,'peers':peers,
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


def abandon(root,name,config,expected_revision,allow_legacy=False):
    """Explicit rollback of local intent, not successful credential migration.

    Caller holds profile/resource/slot locks. Preserve an atomic audit record
    before clearing the barrier; retry can reconcile interruption after unlink.
    """
    root=Path(root).resolve(strict=True);config=Path(config).resolve(strict=True)
    manage.binding.controlled_directory(config)
    if not allow_legacy or not manage.binding.owner.hash_value(expected_revision):
        raise ValueError('abandon requires exact revision and explicit legacy access')
    me=manage.identity(root);profile_id=manage.profile(root,name)
    if os.path.lexists(config/manage.binding.MARKER) or manage.binding.conflicted(root,name):
        raise ValueError('owner intent prevents legacy recovery')
    directory=root/'fleet/auth-migration-history'
    manage.binding.owner.private_directory(directory,create=True)
    manage.binding.owner.sync_directory(directory.parent)
    history=directory/(expected_revision+'.json')
    current=pending(root,name,config)
    previous=None
    if os.path.lexists(history):
        previous=json.loads(manage.binding.owner.private_file(history,8192),object_pairs_hook=manage.binding.owner.unique)
        if (not isinstance(previous,dict) or set(previous)!={'schemaVersion','outcome','migration','revision'}
                or previous['schemaVersion']!=1 or previous['outcome']!='abandoned'
                or previous['revision']!=expected_revision or not isinstance(previous['migration'],dict)
                or previous['migration'].get('profileId')!=profile_id or previous['migration'].get('machine')!=me):
            raise ValueError('invalid migration history')
    if current is None:
        if previous is None:raise ValueError('no matching migration to abandon')
        return {'status':'legacy-unmanaged','migrationId':previous['migration']['migrationId'],'migrationComplete':False}
    if current['state']!='pending' or current['machine']!=me:
        raise ValueError('migration cannot be abandoned here')
    raw=manage.binding.owner.private_file(config/MARKER,4096)
    if hashlib.sha256(raw).hexdigest()!=expected_revision:raise ValueError('migration changed')
    if any(path.name.startswith(expected_revision+'.') for path in entries(root/'fleet/auth-migrations')):
        raise ValueError('prepared peers require coordinated recovery')
    record={'schemaVersion':1,'outcome':'abandoned','migration':current,'revision':expected_revision}
    if previous is not None and previous!=record:raise ValueError('migration history changed')
    if previous is None:
        fd,temporary=tempfile.mkstemp(prefix='.history-',dir=directory)
        try:
            with os.fdopen(fd,'wb') as out:
                out.write(json.dumps(record,sort_keys=True,separators=(',',':')).encode()+b'\n')
                out.flush();os.fsync(out.fileno())
            # The profile/slot locks serialize this operation. Rename keeps
            # the private file single-linked even if the process dies here.
            os.replace(temporary,history);manage.binding.owner.sync_directory(directory)
        finally:
            if os.path.exists(temporary):os.unlink(temporary)
    if manage.binding.owner.private_file(config/MARKER,4096)!=raw:raise ValueError('migration changed')
    os.unlink(config/MARKER);manage.binding.owner.sync_directory(config)
    return {'status':'legacy-unmanaged','migrationId':current['migrationId'],'migrationComplete':False}


def canonical(value):
    return manage.server.codec.canonical(value)+b'\n'


def public_json(path):
    return manage.server.codec.decode_json(manage.server.transport.bounded_file(Path(path),65536))


def atomic(path,value):
    if path.name==MARKER:manage.binding.controlled_directory(path.parent)
    else:manage.binding.owner.private_directory(path.parent,create=True)
    manage.binding.owner.sync_directory(path.parent.parent)
    fd,tmp=tempfile.mkstemp(prefix='.migration-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as out:
            out.write(canonical(value));out.flush();os.fsync(out.fileno())
        os.replace(tmp,path);manage.binding.owner.sync_directory(path.parent)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)


def permission(root,profile_id,peer,allowed=None):
    if not manage.binding.owner.peer_value(peer):raise ValueError('invalid coordinator')
    path=Path(root)/'fleet/auth-migrations'/(profile_id+'.consent.json')
    try:
        manage.binding.owner.private_directory(path.parent)
        peers=json.loads(manage.binding.owner.private_file(path,65536))
        if (not isinstance(peers,list) or len(peers)>1024 or peers!=sorted(set(peers))
                or any(not manage.binding.owner.peer_value(p) for p in peers)):raise ValueError('invalid migration consent')
    except FileNotFoundError:peers=[]
    if allowed is None:return peer in peers
    peers=sorted(set(peers)|{peer}) if allowed else [p for p in peers if p!=peer]
    if len(peers)>1024:raise ValueError('too many migration peers')
    atomic(path,peers)
    return {'status':'allowed' if allowed else 'denied','profileId':profile_id,'peer':peer}


def request(root,name,config,peer,revision):
    current=pending(root,name,config);me=manage.identity(Path(root))
    if (not current or current['state']!='pending' or current['machine']!=me
            or not manage.binding.owner.peer_value(peer) or peer==me
            or not manage.binding.owner.hash_value(revision)
            or hashlib.sha256(manage.binding.owner.private_file(Path(config)/MARKER,4096)).hexdigest()!=revision):
        raise ValueError('migration request changed')
    value={'schemaVersion':1,'coordinator':me,'recipient':peer,'requestId':str(uuid.uuid4()),
           'revision':revision,'migration':current}
    # A lost reply can hide a successfully installed peer barrier. Retain intent
    # before dialing so local abandonment cannot strand that participant.
    atomic(receipt_path(root,revision,peer).with_suffix('.attempt.json'),value)
    return value


def validate_request(value,peer,recipient):
    if (not isinstance(value,dict) or set(value)!={'schemaVersion','coordinator','recipient','requestId','revision','migration'}
            or type(value['schemaVersion']) is not int or value['schemaVersion']!=1
            or value['coordinator']!=peer or value['recipient']!=recipient or peer==recipient
            or not manage.binding.owner.uuid_value(value['requestId'])
            or not manage.binding.owner.hash_value(value['revision'])):raise ValueError('invalid migration request')
    marker=value['migration']
    if not isinstance(marker,dict):raise ValueError('invalid migration marker')
    validate_marker(marker,marker.get('profileId'))
    if (not manage.binding.owner.uuid_value(marker['profileId']) or marker['machine']!=peer
            or hashlib.sha256(canonical(marker)).hexdigest()!=value['revision']):raise ValueError('migration identity mismatch')
    return marker


def accept(root,name,config,peer,payload):
    value=public_json(payload);root=Path(root);config=Path(config)
    marker=validate_request(value,peer,manage.identity(root));profile_id=manage.profile(root,name)
    if marker['profileId']!=profile_id or not permission(root,profile_id,peer):raise ValueError('migration consent required')
    manage.binding.controlled_directory(config)
    current=pending(root,name,config)
    if current:
        if current!=marker or hashlib.sha256(manage.binding.owner.private_file(config/MARKER,4096)).hexdigest()!=value['revision']:
            raise ValueError('conflicting migration')
    else:
        if manage.binding.has_intent(root,name,config):raise ValueError('owner intent prevents migration')
        atomic(config/MARKER,marker)
    return {'request':value,'result':{'status':'peer-prepared','peer':manage.identity(root),'migrationComplete':False}}


def receipt_path(root,revision,peer):
    return Path(root)/'fleet/auth-migrations'/(revision+'.'+hashlib.sha256(peer.encode()).hexdigest()+'.json')


def record(root,name,config,peer,revision,payload,original):
    expected=public_json(original);reply=public_json(payload)
    current=request(root,name,config,peer,revision)
    if expected!=dict(current,requestId=expected.get('requestId')):raise ValueError('migration request changed')
    validate_request(expected,current['coordinator'],peer)
    result={'status':'peer-prepared','peer':peer,'migrationComplete':False}
    if reply!={'request':expected,'result':result}:raise ValueError('wrong migration acknowledgement')
    atomic(receipt_path(root,revision,peer),reply)
    return result


def acknowledged(root,revision,peer,marker):
    try:
        path=receipt_path(root,revision,peer);manage.binding.owner.private_directory(path.parent)
        reply=manage.server.codec.decode_json(manage.binding.owner.private_file(path,65536))
    except FileNotFoundError:return False
    expected=reply['request'];validate_request(expected,manage.identity(Path(root)),peer)
    if (expected['migration']!=marker or expected['revision']!=revision
            or reply!={'request':expected,'result':{'status':'peer-prepared','peer':peer,'migrationComplete':False}}):
        raise ValueError('invalid migration acknowledgement')
    return True


if __name__=='__main__':
    import sys
    try:
        root=Path(sys.argv[1]);value=public_json(sys.argv[3])
        marker=validate_request(value,sys.argv[2],manage.identity(root))
        rows=[row for row in manage.metadata.report(root,None)['profiles']
              if row['profileId']==marker['profileId'] and row['metadataStatus']=='ready']
        if len(rows)!=1:raise ValueError('profile unavailable')
        print(rows[0]['name'])
    except Exception:sys.exit(1)
