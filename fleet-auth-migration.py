#!/usr/bin/env python3
"""Read-only migration inventory and an explicit local migration barrier.

Inventory is read-only. Explicit archival preserves known copies privately for recovery.
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
    archived=None
    if revision:
        _,manifest=archive_manifest(root,name,config,revision)
        if manifest:archived={'state':manifest['phase'],'copies':len(manifest['rows'])}
    for row in peers:
        row['migrationBarrier']='prepared' if revision and acknowledged(root,revision,row['peer'],migration) else 'unacknowledged'
    return {'schemaVersion':1,'profileId':profile_id,'machine':me,'observedAt':int(time.time()),
            'status':'migration-pending' if migration and migration['state']=='pending' else 'migration-invalid' if migration else 'inventory-only',
            'migration':migration,'migrationRevision':revision,'localArchive':archived,'credentialFiles':files,'retainedSyncCopies':copies,'peers':peers,
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
    attempts=[path for path in entries(root/'fleet/auth-migrations') if path.name.startswith(expected_revision+'.') and path.name.endswith('.attempt.json')]
    if attempts:
        plan=recovery_plan(root,name,config,expected_revision,True)
        for request_value in plan:
            if not recovery_confirmed(root,request_value):raise ValueError('peer recovery is unconfirmed')
    restore_archived(root,name,config,expected_revision)
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


# Archival is local evidence only. Private hashes support retry verification;
# neither hashes nor source paths are included in public status.
def archive_read(path, links=1):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid()
                or before.st_mode & 0o022 or stat.S_IMODE(before.st_mode)>0o777 or before.st_nlink>links):raise ValueError('unsafe archive source')
        with os.fdopen(fd,'rb',closefd=False) as stream:data=stream.read(8*1024*1024+1)
        after=os.fstat(fd)
        def identity(s):return [s.st_dev,s.st_ino,s.st_mtime_ns,s.st_size,stat.S_IMODE(s.st_mode)]
        if len(data)>8*1024*1024 or identity(before)!=identity(after):raise ValueError('archive source changed')
        return data,identity(after)
    finally:os.close(fd)


def archive_source(root,config,route):
    if not isinstance(route,list):raise ValueError('invalid archive route')
    if len(route)==2 and route[0]=='slot' and route[1] in FILES:return config/route[1]
    if (len(route)!=3 or route[0]!='conflict' or route[2] not in ('local','remote')
            or not isinstance(route[1],str) or route[1] in ('.','..')
            or not route[1] or any(not (c.isalnum() or c in '-_.') for c in route[1])):
        raise ValueError('invalid archive route')
    directory=root/'fleet'
    for part in ('sync','conflicts',route[1]):
        manage.binding.controlled_directory(directory);directory=directory/part
    manage.binding.controlled_directory(directory)
    return directory/route[2]


def archive_manifest(root,name,config,revision,create=False):
    parent=root/'fleet/auth-archives';directory=parent/revision
    manage.binding.controlled_directory(root/'fleet')
    if not os.path.lexists(parent) and not create:return None,None
    manage.binding.owner.private_directory(parent,create=create)
    if not os.path.lexists(directory) and not create:return directory,None
    manage.binding.owner.private_directory(directory,create=create)
    if create:manage.binding.owner.sync_directory(parent);manage.binding.owner.sync_directory(parent.parent)
    path=directory/'manifest.json'
    if not os.path.lexists(path):return directory,None
    value=json.loads(manage.binding.owner.private_file(path,4*1024*1024),object_pairs_hook=manage.binding.owner.unique)
    info=config.stat()
    if (not isinstance(value,dict) or set(value)!={'schemaVersion','profileId','revision','config','phase','rows'}
            or value['schemaVersion']!=1 or value['profileId']!=manage.profile(root,name)
            or value['revision']!=revision or value['config']!=[info.st_dev,info.st_ino]
            or value['phase'] not in ('archiving','archived','restoring','restored')
            or not isinstance(value['rows'],list) or len(value['rows'])>MAX_ENTRIES):raise ValueError('invalid archive manifest')
    routes=set()
    for row in value['rows']:
        if (not isinstance(row,dict) or set(row)!={'route','parent','fingerprint','digest'}
                or not manage.binding.owner.hash_value(row['digest'])
                or not isinstance(row['parent'],list) or len(row['parent'])!=2
                or not isinstance(row['fingerprint'],list) or len(row['fingerprint'])!=5
                or any(type(v) is not int or v<0 for v in row['parent']+row['fingerprint'])
                or row['fingerprint'][4]>0o777 or row['fingerprint'][4]&0o022):raise ValueError('invalid archive row')
        source=archive_source(root,config,row['route']);parent_info=source.parent.stat()
        route=tuple(row['route'])
        if route in routes or row['parent']!=[parent_info.st_dev,parent_info.st_ino]:raise ValueError('archive path changed')
        routes.add(route)
    return directory,value


def archive_bytes(path,data):
    # The deterministic partial file lets a retry reconcile a hard kill before
    # or after publication without leaving an untracked credential copy.
    partial=path.with_name(path.name+'.partial')
    if not os.path.lexists(path):
        fd=os.open(partial,os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
        try:
            info=os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid()
                    or info.st_mode&0o077 or info.st_nlink!=1):raise ValueError('unsafe partial archive')
            os.ftruncate(fd,0)
            with os.fdopen(fd,'wb',closefd=False) as out:out.write(data);out.flush();os.fsync(fd)
            os.link(partial,path,follow_symlinks=False);manage.binding.owner.sync_directory(path.parent)
        finally:os.close(fd)
    if os.path.lexists(partial):
        a=partial.lstat();b=path.lstat()
        if (a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino):raise ValueError('partial archive changed')
        partial.unlink();manage.binding.owner.sync_directory(path.parent)



def archive(root,name,config,revision):
    root=Path(root).resolve(strict=True);config=Path(config).resolve(strict=True)
    manage.binding.controlled_directory(config)
    current=pending(root,name,config)
    if (not manage.binding.owner.hash_value(revision) or not current or current.get('state')!='pending'
            or hashlib.sha256(manage.binding.owner.private_file(config/MARKER,4096)).hexdigest()!=revision
            or os.path.lexists(config/manage.binding.MARKER) or manage.binding.conflicted(root,name)):
        raise ValueError('migration changed')
    directory,value=archive_manifest(root,name,config,revision,True)
    if value is None:
        routes=[['slot',file] for file in FILES if os.path.lexists(config/file)]
        conflict_root=root/'fleet/sync/conflicts'
        for ancestor in (root/'fleet/sync',conflict_root):
            if os.path.lexists(ancestor):manage.binding.controlled_directory(ancestor)
        for entry in entries(conflict_root):
            manage.binding.controlled_directory(entry)
            address=metadata(entry/'meta').get('addr','').split('|')
            if len(address)!=4:raise ValueError('invalid conflict metadata')
            if address[0] in ('auth','settings','mcp') and address[1:3]==[name,'codex']:
                routes.extend(['conflict',entry.name,side] for side in ('local','remote') if os.path.lexists(entry/side))
        if len(routes)>MAX_ENTRIES:raise ValueError('too many archive copies')
        rows=[]
        for route in routes:
            source=archive_source(root,config,route);data,info=archive_read(source);parent_info=source.parent.stat()
            rows.append({'route':route,'parent':[parent_info.st_dev,parent_info.st_ino],
                         'fingerprint':info,'digest':hashlib.sha256(data).hexdigest()})
        info=config.stat()
        value={'schemaVersion':1,'profileId':current['profileId'],'revision':revision,'config':[info.st_dev,info.st_ino],
               'phase':'archiving','rows':rows}
        atomic(directory/'manifest.json',value)
    if value['phase'] not in ('archiving','archived'):raise ValueError('archive is recovering')
    for index,row in enumerate(value['rows']):
        source=archive_source(root,config,row['route']);blob=directory/(str(index)+'.blob')
        if os.path.lexists(source):
            if value['phase']=='archived':raise ValueError('new credential copy appeared')
            data,info=archive_read(source)
            if info!=row['fingerprint'] or hashlib.sha256(data).hexdigest()!=row['digest']:raise ValueError('source changed')
            archive_bytes(blob,data)
        data,_=archive_read(blob)
        if hashlib.sha256(data).hexdigest()!=row['digest']:raise ValueError('archive copy changed')
        manage.binding.owner.sync_directory(directory)
        if os.path.lexists(source):
            data,info=archive_read(source)
            if info!=row['fingerprint'] or hashlib.sha256(data).hexdigest()!=row['digest']:raise ValueError('source changed')
            source.unlink()
        manage.binding.owner.sync_directory(source.parent)
    value['phase']='archived';atomic(directory/'manifest.json',value)
    return inventory(root,name,config)


def restore_archived(root,name,config,revision):
    directory,value=archive_manifest(root,name,config,revision)
    if value is None:return
    value['phase']='restoring';atomic(directory/'manifest.json',value)
    for index,row in enumerate(value['rows']):
        source=archive_source(root,config,row['route']);blob=directory/(str(index)+'.blob')
        temporary=source.parent/('.n2-restore-'+revision+'-'+str(index))
        if os.path.lexists(source):
            data,_=archive_read(source,2)
            if hashlib.sha256(data).hexdigest()!=row['digest']:raise ValueError('new file prevents restoration')
        else:
            data,_=archive_read(blob)
            if hashlib.sha256(data).hexdigest()!=row['digest']:raise ValueError('archive copy changed')
            archive_bytes(temporary,data)
            restored,_=archive_read(temporary)
            if restored!=data:raise ValueError('restore temporary changed')
            temporary.chmod(row['fingerprint'][4])
            os.link(temporary,source,follow_symlinks=False)
            manage.binding.owner.sync_directory(source.parent)
        if os.path.lexists(temporary.with_name(temporary.name+'.partial')):archive_bytes(temporary,data)
        if os.path.lexists(blob.with_name(blob.name+'.partial')):archive_bytes(blob,data)
        if os.path.lexists(temporary):
            restored,_=archive_read(temporary,2)
            if hashlib.sha256(restored).hexdigest()!=row['digest']:raise ValueError('restore temporary changed')
            temporary.unlink();manage.binding.owner.sync_directory(source.parent)
        # A retry must persist an earlier source publication even if its
        # temporary link has already disappeared before the prior sync failed.
        manage.binding.owner.sync_directory(source.parent)
        if os.path.lexists(blob):blob.unlink()
        manage.binding.owner.sync_directory(directory)
    value['phase']='restored';atomic(directory/'manifest.json',value)


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
    if os.path.lexists(Path(root)/'fleet/auth-migrations'/(revision+'.abort.json')):raise ValueError('migration recovery has begun')
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
    if os.path.lexists(recovery_tombstone(root,value['revision'])):raise ValueError('migration was abandoned')
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


def public_private_json(path):
    manage.binding.owner.private_directory(path.parent)
    return manage.server.codec.decode_json(manage.binding.owner.private_file(path,65536))


def recovery_plan(root,name,config,revision,allow_legacy=False):
    root=Path(root);config=Path(config);current=pending(root,name,config)
    if not allow_legacy or not manage.binding.owner.hash_value(revision):raise ValueError('explicit recovery required')
    if current is None:
        abandon(root,name,config,revision,True)
        return []
    me=manage.identity(root)
    if (current.get('state')!='pending' or current['machine']!=me
            or hashlib.sha256(manage.binding.owner.private_file(config/MARKER,4096)).hexdigest()!=revision
            or os.path.lexists(config/manage.binding.MARKER) or manage.binding.conflicted(root,name)):
        raise ValueError('migration changed')
    directory=root/'fleet/auth-migrations';plan_path=directory/(revision+'.abort.json')
    plan=[]
    for path in entries(directory):
        if not path.name.startswith(revision+'.') or not path.name.endswith('.attempt.json'):continue
        value=public_private_json(path);peer=value['recipient']
        validate_request(value,me,peer)
        if (value['migration']!=current or value['revision']!=revision
                or path!=receipt_path(root,revision,peer).with_suffix('.attempt.json')):raise ValueError('invalid participant')
        plan.append(value)
    if os.path.lexists(plan_path):
        if public_private_json(plan_path)!=plan:raise ValueError('recovery participants changed')
        manage.binding.owner.sync_directory(directory)
    else:atomic(plan_path,plan)
    return plan


def recovery_tombstone(root,revision):
    return Path(root)/'fleet/auth-migrations'/(revision+'.peer-abandoned.json')


def recovery_reply(value):
    return {'request':value,'result':{'status':'peer-abandoned','peer':value['recipient'],'migrationComplete':False}}


def recover(root,name,config,peer,payload):
    root=Path(root);config=Path(config);value=public_json(payload)
    marker=validate_request(value,peer,manage.identity(root));profile_id=manage.profile(root,name)
    if marker['profileId']!=profile_id:raise ValueError('profile changed')
    manage.binding.controlled_directory(config)
    current=pending(root,name,config);path=recovery_tombstone(root,value['revision'])
    tombstone={'migration':marker,'revision':value['revision'],'outcome':'abandoned'}
    previous=public_private_json(path) if os.path.lexists(path) else None
    if previous is not None and previous!=tombstone:raise ValueError('invalid recovery history')
    if previous is not None:manage.binding.owner.sync_directory(path.parent)
    if previous is not None and current!=marker:
        manage.binding.owner.sync_directory(config)
        return recovery_reply(value)
    if os.path.lexists(config/manage.binding.MARKER) or manage.binding.conflicted(root,name):raise ValueError('owner intent prevents recovery')
    if current is not None:
        if current!=marker or hashlib.sha256(manage.binding.owner.private_file(config/MARKER,4096)).hexdigest()!=value['revision']:
            raise ValueError('conflicting migration')
    elif previous is None and not permission(root,profile_id,peer):raise ValueError('migration consent required')
    if current is not None:restore_archived(root,name,config,value['revision'])
    if previous is None:atomic(path,tombstone)
    if current is not None:
        os.unlink(config/MARKER);manage.binding.owner.sync_directory(config)
    return recovery_reply(value)


def recovery_confirmed(root,value):
    receipt=receipt_path(root,value['revision'],value['recipient']).with_suffix('.recovered.json')
    try:reply=public_private_json(receipt)
    except FileNotFoundError:return False
    if reply!=recovery_reply(value):raise ValueError('invalid recovery receipt')
    manage.binding.owner.sync_directory(receipt.parent)
    return True


def record_recovery(root,name,config,peer,revision,payload,original):
    expected=public_json(original);reply=public_json(payload)
    plan=recovery_plan(root,name,config,revision,True)
    if expected not in plan or expected['recipient']!=peer or reply!=recovery_reply(expected):
        raise ValueError('wrong recovery acknowledgement')
    atomic(receipt_path(root,revision,peer).with_suffix('.recovered.json'),reply)
    return reply['result']


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
