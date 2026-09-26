#!/usr/bin/env python3
"""Exercise an installed Codex TUI against a disposable signed-owner fixture.

No live provider calls or credentials. Run explicitly with --codex PATH.
"""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import termios
import time

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--codex',required=True)
parser.add_argument('--artifacts',required=True)
parser.add_argument('--resume-roundtrip',action='store_true')
args=parser.parse_args()
native=str(Path(args.codex).resolve(strict=True))
artifacts=Path(args.artifacts);artifacts.mkdir(parents=True,exist_ok=True,mode=0o700)
spec=importlib.util.spec_from_file_location('fixtures',ROOT/'scripts/test-fleet-auth-bridge.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
fixture=m.BridgeIntegrationTests('test_actual_cli_connects_to_remote_owner_without_forwarding_credentials')
fixture.setUp();process=None;master=None
try:
    (fixture.wire.bin/'settings.json').write_text(json.dumps({'allowExternalHome':True,'nativeFrontend':True}))
    provider=fixture.wire.bin/'fixture-provider';(fixture.wire.bin/'codex').rename(provider)
    wrapper=fixture.wire.bin/'codex'
    wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\nargs=sys.argv[1:]\n'
        +'if "--remote" in args: os.execv('+repr(native)+',["codex",*args])\n'
        +'os.execv('+repr(str(provider))+',["codex",*args])\n')
    wrapper.chmod(0o700)
    for attempt in range(2 if args.resume_roundtrip else 1):
        native_args=['resume','01990000-0000-7000-8000-000000000001','--no-alt-screen','hello again'] if attempt else ['--no-alt-screen','hello']
        master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,0,0))
        process=subprocess.Popen([str(ROOT/'agents'),'run','Work','--vendor','codex',*native_args],
            stdin=slave,stdout=slave,stderr=slave,start_new_session=True,
            env=dict(os.environ,N2_AGENTS_ROOT=str(fixture.root),TERM='xterm-256color'))
        os.close(slave);output=bytearray();deadline=time.monotonic()+20
        while time.monotonic()<deadline and process.poll() is None:
            ready,_,_=select.select([master],[],[],.1)
            if ready:
                try:data=os.read(master,65536)
                except OSError:break
                output.extend(data)
                if b'\x1b[6n' in data:os.write(master,b'\x1b[1;1R')
                if b'N2 native frontend fixture completed' in output:break
        (artifacts/('terminal-resume.txt' if attempt else 'terminal.txt')).write_bytes(output)
        assert b'N2 native frontend fixture completed' in output,'native TUI did not render fixture response'
        # Keep draining while the native client restores its terminal on exit.
        def drain_wait(seconds):
            deadline=time.monotonic()+seconds
            while process.poll() is None and time.monotonic()<deadline:
                ready,_,_=select.select([master],[],[],.1)
                if ready:
                    try:output.extend(os.read(master,65536))
                    except OSError:time.sleep(.05)
            return process.poll() is not None
        os.write(master,b'\x03');time.sleep(.2);os.write(master,b'\x03')
        assert drain_wait(8),'native TUI did not exit after interruption'
        assert process.returncode==0,'native TUI exited with an error'
        (artifacts/('terminal-resume.txt' if attempt else 'terminal.txt')).write_bytes(output)
        os.close(master);master=None
    journal=m.m.load('native_tui_store','usage-store.py').Journal(fixture.root)
    try:
        summary=journal.token_summary()
        assert summary['uniqueTasks']==(2 if args.resume_roundtrip else 1),summary
        if args.resume_roundtrip:assert sum(g['unknownTokenTasks'] for g in summary['groups'])==1,summary
        assert sum(g['reportedTotalTokens'] for g in summary['groups'])==60,summary
        assert all(g['accountHash']==fixture.wire.context['accountHash'] for g in summary['groups']),summary
    finally:journal.db.close()
    methods=[json.loads(line)['method'] for line in (fixture.wire.bin/'trace.jsonl').read_text().splitlines()]
    result={'renderedCompletion':True,'resumed':args.resume_roundtrip,'tasks':summary['uniqueTasks'],'tokens':60,'exit':process.returncode,'methods':methods}
    (artifacts/'result.json').write_text(json.dumps(result))
    print(json.dumps(result))
finally:
    trace=fixture.wire.bin/'trace.jsonl'
    if trace.exists():(artifacts/'provider-trace.jsonl').write_bytes(trace.read_bytes())
    if process is not None and process.poll() is None:
        process.terminate()
        deadline=time.monotonic()+10
        while process.poll() is None and time.monotonic()<deadline:
            ready,_,_=select.select([master],[],[],.1)
            if ready:
                try:output.extend(os.read(master,65536))
                except OSError:time.sleep(.05)
        if process.poll() is None:process.kill()
        process.wait(timeout=5)
    if master is not None:os.close(master)
    fixture.doCleanups()
