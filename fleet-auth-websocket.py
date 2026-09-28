#!/usr/bin/env python3
"""Bounded WebSocket framing for the private Unix-socket Codex TUI relay."""
import base64
import hashlib
import socket
import struct
import threading

LIMIT=4*1024*1024

class Stream:
    def __init__(self,connection):
        self.socket=connection;self.closed=False;self.lock=threading.Lock()
        connection.settimeout(10)
        request=bytearray()
        while not request.endswith(b'\r\n\r\n'):
            if len(request)>=16384:raise ValueError('oversized handshake')
            byte=connection.recv(1)
            if not byte:raise ValueError('closed handshake')
            request.extend(byte)
        lines=request.decode('ascii').split('\r\n')
        if not lines[0].startswith('GET ') or not lines[0].endswith(' HTTP/1.1'):raise ValueError('invalid upgrade')
        headers={}
        for line in lines[1:-2]:
            key,sep,value=line.partition(':');key=key.lower()
            if not sep or key in headers:raise ValueError('invalid headers')
            headers[key]=value.strip()
        key=headers.get('sec-websocket-key','')
        if (headers.get('upgrade','').lower()!='websocket' or headers.get('sec-websocket-version')!='13'
                or 'upgrade' not in [v.strip().lower() for v in headers.get('connection','').split(',')]
                or 'origin' in headers or len(base64.b64decode(key,validate=True))!=16):
            raise ValueError('invalid websocket handshake')
        accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        connection.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
        connection.settimeout(.5)

    def exact(self,count):
        result=bytearray()
        while len(result)<count and not self.closed:
            try:part=self.socket.recv(count-len(result))
            except socket.timeout:continue
            if not part:raise EOFError()
            result.extend(part)
        if len(result)!=count:raise EOFError()
        return bytes(result)

    def frame(self,opcode,payload):
        size=len(payload)
        header=bytes([0x80|opcode,size]) if size<126 else bytes([0x80|opcode,126])+struct.pack('!H',size) if size<65536 else bytes([0x80|opcode,127])+struct.pack('!Q',size)
        with self.lock:self.socket.sendall(header+payload)

    def readline(self,limit):
        data=bytearray();started=False
        try:
            while True:
                first,second=self.exact(2);final=bool(first&128);opcode=first&15
                if first&112 or not second&128:raise ValueError('invalid websocket frame')
                size=second&127
                if size==126:size=struct.unpack('!H',self.exact(2))[0]
                elif size==127:size=struct.unpack('!Q',self.exact(8))[0]
                if size>min(LIMIT,limit) or (opcode>=8 and (not final or size>125)):
                    raise ValueError('oversized websocket frame')
                mask=self.exact(4);payload=self.exact(size)
                payload=bytes(value^mask[i%4] for i,value in enumerate(payload))
                if opcode==8:return b''
                if opcode==9:self.frame(10,payload);continue
                if opcode==10:continue
                if opcode not in (0,1) or (opcode==0)!=started:raise ValueError('invalid websocket continuation')
                started=True;data.extend(payload)
                if len(data)>min(LIMIT,limit):raise ValueError('oversized websocket message')
                if final:
                    data.decode('utf-8');return bytes(data)+b'\n'
        except EOFError:return b''

    def write(self,raw):
        if len(raw)>LIMIT:raise ValueError('oversized websocket output')
        self.frame(1,raw)

    def flush(self):pass

    def close(self):
        self.closed=True
        try:self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:pass
        self.socket.close()
