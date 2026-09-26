#!/usr/bin/env python3
"""Transfer one saved Codex rollout without credentials or account rebinding."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('session_bridge',ROOT/'fleet-auth-bridge.py')
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)
owner=bridge.client.binding.owner
LIMIT=16*1024*1024
FIELDS={'schemaVersion','thread','record','cwd','model','history'}


def profile(root,record):
    metadata=bridge.client.load('transfer_metadata','profile-metadata.py').report(root,None)['profiles']
    rows=[row for row in metadata if row['profileId']==record['profileId']]
    if len(rows)!=1 or rows[0]['metadataStatus']!='ready':raise ValueError('profile identity unavailable')
    name=rows[0]['name'];config=Path(root)/name/'codex'
    # Check current routing health, but never replace the saved account with it.
    bridge.client.for_profile(root,config,name)
    return config


def home_path(sessions,record,cwd):
    key=hashlib.sha256(json.dumps([record,os.path.realpath(cwd)],sort_keys=True).encode()).hexdigest()
    return sessions.base/'homes'/key


def history(raw,thread):
    if not raw or len(raw)>LIMIT or not raw.endswith(b'\n'):raise ValueError('incomplete or oversized history')
    rows=[json.loads(line,object_pairs_hook=owner.unique) for line in raw.splitlines()]
    if any(not isinstance(row,dict) or not isinstance(row.get('type'),str) or not isinstance(row.get('payload'),dict) for row in rows):
        raise ValueError('malformed history')
    if rows[0]['type']!='session_meta' or rows[0]['payload'].get('id')!=thread:
        raise ValueError('history thread mismatch')
    if any(row['type']=='session_meta' for row in rows[1:]):raise ValueError('multiple histories')
    return raw.decode('utf-8')


def history_directory(path):
    info=path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o022:
        raise ValueError('unsafe history directory')


def read_history(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid() or before.st_mode&0o022 or before.st_nlink!=1:
            raise ValueError('unsafe history file')
        with os.fdopen(fd,'rb',closefd=False) as stream:raw=stream.read(LIMIT+1)
        after=os.fstat(fd)
        signature=lambda info:(info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
        if signature(before)!=signature(after) or signature(after)!=signature(path.lstat()):
            raise ValueError('history changed during snapshot')
        return raw
    finally:os.close(fd)


def snapshot(root,thread,cwd):
    sessions=bridge.Sessions(root);saved=sessions.read(thread);record=saved['record']
    profile(root,record)
    home=home_path(sessions,record,saved['cwd']);owner.private_directory(home)
    directory=home/'sessions';history_directory(directory)
    candidates=[]
    for parent,dirs,files in os.walk(directory,followlinks=False):
        history_directory(Path(parent))
        for name in dirs:history_directory(Path(parent)/name)
        candidates.extend(Path(parent)/name for name in files if name.startswith('rollout-') and name.endswith('-'+thread+'.jsonl'))
    if len(candidates)!=1:raise ValueError('one saved rollout required')
    raw=read_history(candidates[0])
    model=sessions.model(thread)
    if sessions.read(thread)!=saved:raise ValueError('session binding changed')
    return {'schemaVersion':1,'thread':thread,'record':record,'cwd':cwd,'model':model,'history':history(raw,thread)}


def reconcile(path):
    staged=path.with_name('.import-'+path.name)
    if not os.path.lexists(staged):return staged
    info=staged.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:
        raise ValueError('unsafe import staging')
    if os.path.lexists(path):
        final=path.lstat()
        if (info.st_dev,info.st_ino)!=(final.st_dev,final.st_ino) or info.st_nlink!=2:
            raise ValueError('conflicting import staging')
    elif info.st_nlink!=1:raise ValueError('unsafe import links')
    staged.unlink();owner.sync_directory(path.parent)
    return staged


def publish(path,raw):
    staged=reconcile(path)
    if os.path.lexists(path):
        if owner.private_file(path,LIMIT)!=raw:raise ValueError('destination history conflicts')
        owner.sync_directory(path.parent);return
    fd=os.open(staged,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as out:out.write(raw);out.flush();os.fsync(out.fileno())
    # A deterministic staging name lets the next locked import reconcile both
    # sides of link publication after SIGKILL, without overwriting any target.
    os.link(staged,path)
    staged.unlink();owner.sync_directory(path.parent)


def receive(root,value):
    if not isinstance(value,dict) or set(value)!=FIELDS or type(value['schemaVersion']) is not int or value['schemaVersion']!=1:
        raise ValueError('invalid transfer schema')
    sessions=bridge.Sessions(root);thread=value['thread'];path=sessions.thread_path(thread)
    record=value['record'];bridge.client.binding.validate(record,record.get('profileId') if isinstance(record,dict) else None)
    cwd=value['cwd'];model=value['model']
    if not isinstance(cwd,str) or not os.path.isabs(cwd) or not os.path.isdir(cwd):raise ValueError('destination directory unavailable')
    cwd=os.path.realpath(cwd)
    if model is not None and (not isinstance(model,str) or not 0<len(model)<=512):raise ValueError('invalid selected model')
    if not isinstance(value['history'],str):raise ValueError('invalid history')
    raw=value['history'].encode();history(raw,thread);profile(root,record)
    # Serialize imports. A complete immutable thread record is published last,
    # so interrupted staging is invisible to session discovery and resume.
    lock=sessions.base/'.transfer-lock'
    fd=os.open(lock,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_NONBLOCK,0o600)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or info.st_mode&0o077:
            raise ValueError('unsafe transfer lock')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        reconcile(path)
        if os.path.lexists(path):
            if not sessions.matches(thread,record,cwd) or sessions.model(thread)!=model:raise ValueError('destination session conflicts')
        home=home_path(sessions,record,cwd);owner.private_directory(home,create=True)
        # The fixed destination path is derived locally, never supplied by sender.
        directory=home/'sessions';owner.private_directory(directory,create=True)
        target=directory/('rollout-2000-01-01T00-00-00-'+thread+'.jsonl')
        reconcile(target)
        existing=list(directory.rglob('rollout-*-'+thread+'.jsonl'))
        if any(other!=target for other in existing):raise ValueError('destination has another rollout')
        publish(target,raw)
        owner.sync_directory(directory);owner.sync_directory(home);owner.sync_directory(home.parent)
        if not os.path.lexists(path):
            publish(path.with_suffix('.model'),json.dumps(model).encode())
            saved={'schemaVersion':1,'thread':thread,'record':record,'cwd':cwd}
            publish(path,json.dumps(saved,sort_keys=True,separators=(',',':')).encode())
        owner.sync_directory(path.parent);owner.sync_directory(sessions.base);owner.sync_directory(sessions.base.parent)
        return {'thread':thread,'cwd':cwd,'status':'saved'}
    finally:os.close(fd)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('root');sub=parser.add_subparsers(dest='action',required=True)
    export=sub.add_parser('snapshot');export.add_argument('thread');export.add_argument('--cwd',required=True)
    accept=sub.add_parser('receive');accept.add_argument('payload')
    args=parser.parse_args()
    try:
        if args.action=='snapshot':value=snapshot(args.root,args.thread,args.cwd)
        else:
            raw=owner.private_file(Path(args.payload),LIMIT*6+16384)
            value=receive(args.root,json.loads(raw,object_pairs_hook=owner.unique))
        print(json.dumps(value,separators=(',',':'),allow_nan=False));return 0
    except (ValueError,OSError,TypeError,KeyError):
        print('agents: saved-session transfer refused',file=sys.stderr);return 1

if __name__=='__main__':sys.exit(main())
