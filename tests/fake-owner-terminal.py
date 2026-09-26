#!/usr/bin/env python3
"""Synthetic terminal frontend; delegates app-server calls to fake-owner-codex."""
import base64
import json
import os
from pathlib import Path
import socket
import struct
import sys

if '--remote' not in sys.argv:
    os.execv(sys.executable,[sys.executable,str(Path(__file__).with_name('provider')),*sys.argv[1:]])
endpoint=sys.argv[sys.argv.index('--remote')+1]
assert endpoint.startswith('unix://')
assert not (Path(os.environ['CODEX_HOME'])/'auth.json').exists()
assert not any(k in os.environ for k in ('OPENAI_API_KEY','CODEX_ACCESS_TOKEN','CODEX_API_KEY'))
connection=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);connection.settimeout(5);connection.connect(endpoint[7:])
connection.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+base64.b64encode(b'0123456789abcdef')+b'\r\n\r\n')
header=b''
while not header.endswith(b'\r\n\r\n'):header+=connection.recv(1)
assert b'101 Switching' in header

def exact(size):
    data=b''
    while len(data)<size:
        part=connection.recv(size-len(data));assert part;data+=part
    return data

def exchange(message):
    raw=json.dumps(message).encode();assert len(raw)<126;mask=b'abcd'
    connection.sendall(bytes([129,128|len(raw)])+mask+bytes(v^mask[i%4] for i,v in enumerate(raw)))
    first,length=exact(2);assert first==129 and not length&128
    if length==126:length=struct.unpack('!H',exact(2))[0]
    elif length==127:length=struct.unpack('!Q',exact(8))[0]
    return json.loads(exact(length))
assert exchange({'id':1,'method':'initialize'})['id']==1
account=exchange({'id':2,'method':'account/read'})
assert account['id']==2 and account['result']['account']['email']=='fixture@example.invalid'
connection.sendall(b'\x88\x80abcd');connection.close()
print('terminal-connected',flush=True)
