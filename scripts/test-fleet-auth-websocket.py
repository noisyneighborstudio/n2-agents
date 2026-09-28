#!/usr/bin/env python3
import base64
import importlib.util
import os
from pathlib import Path
import socket
import struct
import threading
import unittest
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('ws',ROOT/'fleet-auth-websocket.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class WebSocketTests(unittest.TestCase):
    def setUp(self):
        self.server,self.client=socket.socketpair();self.addCleanup(self.server.close);self.addCleanup(self.client.close)
        key=base64.b64encode(b'0123456789abcdef')
        self.client.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+b'\r\n\r\n')
        self.stream=m.Stream(self.server);self.addCleanup(self.stream.close)
        self.assertIn(b'101 Switching',self.client.recv(4096))
    def send(self,payload,opcode=1,final=True):
        mask=b'abcd';size=len(payload)
        header=bytes([(128 if final else 0)|opcode,128|size]) if size<126 else bytes([(128 if final else 0)|opcode,254])+struct.pack('!H',size)
        self.client.sendall(header+mask+bytes(v^mask[i%4] for i,v in enumerate(payload)))
    def test_masked_fragmented_text_and_ping(self):
        self.send(b'{"id":',final=False);self.send(b'ping',opcode=9);self.send(b'1}',opcode=0)
        self.assertEqual(self.stream.readline(4096),b'{"id":1}\n')
        self.assertEqual(self.client.recv(4096),b'\x8a\x04ping')
    def test_output_is_unmasked_text_and_extended_input_is_bounded(self):
        self.stream.write(b'{"id":1}\n');self.assertEqual(self.client.recv(4096),b'\x81\x09{"id":1}\n')
        self.send(b'x'*200)
        with self.assertRaises(ValueError):self.stream.readline(100)
    def test_unmasked_and_binary_messages_are_rejected(self):
        self.client.sendall(b'\x81\x02{}')
        with self.assertRaises(ValueError):self.stream.readline(4096)
    def test_fragment_total_is_bounded(self):
        self.send(b'a'*80,final=False);self.send(b'b'*80,opcode=0)
        with self.assertRaises(ValueError):self.stream.readline(100)
    def test_close_is_end_of_stream(self):
        self.send(b'',opcode=8);self.assertEqual(self.stream.readline(4096),b'')

if __name__=='__main__':unittest.main()
