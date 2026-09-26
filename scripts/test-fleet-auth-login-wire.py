#!/usr/bin/env python3
"""Real signatures over synthetic login-control replies, with disposable keys."""
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('wire',ROOT/'fleet-auth-login-wire.py')
wire=importlib.util.module_from_spec(spec);spec.loader.exec_module(wire)

class LoginWireTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.key=Path(self.temp.name)/'owner'
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(self.key)],check=True)
        self.public=Path(str(self.key)+'.pub').read_bytes();self.owner=wire.codec.public_identity(self.public)[0]
        self.context={'schemaVersion':1,'owner':self.owner,'recipient':'SHA256:'+'A'*43,
            'nonce':secrets.token_hex(32),'expiresAt':time.time()+20,'operationId':str(uuid.uuid4()),
            'action':'start','profileId':str(uuid.uuid4()),'grantId':str(uuid.uuid4()),
            'ownershipGeneration':str(uuid.uuid4()),'accountHash':'a'*64,'bindingRevision':'b'*64,'replaceAccount':False}
        self.result={'status':'login-required','binding':None,'challenge':{'type':'chatgptDeviceCode',
            'loginId':str(uuid.uuid4()),'verificationUrl':'https://auth.openai.com/codex/device','userCode':'TEST-1234'}}
    def sign(self):return wire.sign(self.context,self.result,self.key,time.monotonic()+3)
    def verify(self,context=None):return wire.Verifier(context or self.context,self.public,time.monotonic()+3)
    def test_challenge_real_signature_and_single_use(self):
        response=self.sign();verifier=self.verify()
        self.assertEqual(verifier.verify(response),self.result)
        with self.assertRaises(ValueError):verifier.verify(response)
    def test_wrong_request_operation_recipient_and_action_are_rejected(self):
        response=self.sign()
        for key,value in [('operationId',str(uuid.uuid4())),('nonce',secrets.token_hex(32)),
                          ('recipient','SHA256:'+'B'*43),('action','cancel'),('bindingRevision','c'*64)]:
            with self.subTest(field=key):
                context=dict(self.context);context[key]=value
                with self.assertRaises(ValueError):self.verify(context).verify(response)
    def test_failed_verification_consumes_request(self):
        response=self.sign();verifier=self.verify()
        with self.assertRaises(ValueError):verifier.verify(b'private provider error')
        with self.assertRaises(ValueError):verifier.verify(response)
    def test_extra_secrets_and_untrusted_challenge_are_not_signable(self):
        for changes in ({'accessToken':'secret'},{'refreshToken':'secret'}):
            original=dict(self.result);self.result.update(changes)
            with self.assertRaises(ValueError):self.sign()
            self.result=original
        self.result['challenge']['verificationUrl']='https://other.invalid/device'
        with self.assertRaises(ValueError):self.sign()
    def test_completed_binding_requires_same_account_unless_explicitly_replaced(self):
        record={'schemaVersion':1,'provider':'codex','credentialStore':'owner-file',
            'profileId':self.context['profileId'],'grantId':str(uuid.uuid4()),'owner':self.owner,
            'ownershipGeneration':str(uuid.uuid4()),'accountHash':'c'*64}
        self.result={'status':'completed','challenge':None,'binding':record}
        with self.assertRaises(ValueError):self.sign()
        self.context['replaceAccount']=True
        self.assertEqual(self.verify().verify(self.sign()),self.result)
        record['owner']='SHA256:'+'B'*43
        with self.assertRaises(ValueError):self.sign()
    def test_context_is_frozen_and_expired_requests_fail(self):
        response=self.sign();verifier=self.verify()
        self.context['operationId']=str(uuid.uuid4())
        self.assertEqual(verifier.verify(response),self.result)
        self.context['expiresAt']=time.time()-1
        with self.assertRaises(ValueError):self.verify()
    def test_login_signature_cannot_be_used_as_token_signature(self):
        import base64
        envelope=json.loads(self.sign())
        with self.assertRaises(ValueError):
            wire.codec.public_signature(base64.b64decode(envelope['signature']),self.public)

class LoginTransportTests(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('transport_fixture',ROOT/'scripts/test-fleet-auth-transport.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        self.fixture=module.TransportTests('test_signed_request_and_memory_only_verified_response')
        self.addCleanup(self.fixture.doCleanups);self.fixture.setUp();self.transport=module.m
        self.context=dict(self.fixture.context)
        self.context.pop('rejectedTokenGeneration')
        self.context.update(operationId=str(uuid.uuid4()),action='start',profileId=str(uuid.uuid4()),
                            bindingRevision='b'*64,replaceAccount=False)
        script=module.SSH
        script=script.replace("assert b'verb=auth-token", "assert b'verb=auth-login")
        begin=script.index("spec = importlib.util.spec_from_file_location('codec'")
        script=script[:begin]+"""spec=importlib.util.spec_from_file_location('login_wire',repo/'fleet-auth-login-wire.py')
wire=importlib.util.module_from_spec(spec);spec.loader.exec_module(wire)
result={'status':'login-required','binding':None,'challenge':{'type':'chatgptDeviceCode',
        'loginId':'00000000-0000-4000-8000-000000000001','verificationUrl':'https://auth.openai.com/codex/device','userCode':'TEST-1234'}}
reply=wire.sign(context,result,root/'owner/fleet/identity/id_ed25519',time.monotonic()+2)
sys.stdout.buffer.write(reply)
"""
        (self.fixture.bin/'ssh').write_text(script)
    def test_signed_login_challenge_uses_pinned_carrier_without_response_spooling(self):
        result=self.transport.exchange(self.fixture.base/'client',self.context,self.fixture.public,
                                       time.monotonic()+5,protocol='login')
        self.assertEqual(result['challenge']['userCode'],'TEST-1234')
        for path in self.fixture.base.rglob('*'):
            if path.is_file() and path.name!='ssh':self.assertNotIn(b'TEST-1234',path.read_bytes(),str(path))
    def test_generic_login_send_is_refused_before_dial(self):
        (self.fixture.bin/'ssh').write_text('#!/bin/sh\ntouch "$FIXTURE_ROOT/was-dialed"\nexit 99\n')
        request=self.fixture.base/'login-request';request.write_text(json.dumps(self.context))
        result=subprocess.run([str(ROOT/'agents'),'fleet','send',self.fixture.identities['owner'],
            '--verb','auth-login','--payload-file',str(request)],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.fixture.base/'client')),capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'private-carrier-required',result.stderr)
        self.assertFalse((self.fixture.base/'was-dialed').exists())

if __name__=='__main__':unittest.main()
