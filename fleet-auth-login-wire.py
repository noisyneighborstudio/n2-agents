#!/usr/bin/env python3
"""Request-bound login-control replies. Provider grants never cross this wire."""
import base64
import importlib.util
import math
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parent

def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

codec=load('n2_login_codec','fleet-auth-response.py')
binding=load('n2_login_binding','fleet-auth-binding.py')
NAMESPACE='n2-agents-login-response-v1'
MAX_BYTES=16384
FIELDS={'schemaVersion','owner','recipient','nonce','expiresAt','operationId','action',
        'profileId','grantId','ownershipGeneration','accountHash','bindingRevision','replaceAccount'}
STATES={'starting','login-required','verifying','verified','completed','cancelled','failed','busy'}


def validate_context(context):
    if not isinstance(context,dict) or set(context)!=FIELDS:raise ValueError('invalid login context')
    token={key:context[key] for key in ('schemaVersion','owner','recipient','nonce','expiresAt',
                                      'grantId','ownershipGeneration','accountHash')}
    token['rejectedTokenGeneration']=None
    codec.validate_context(token,time.time())
    if (context['action'] not in ('start','status','finish','cancel')
            or not codec.valid_uuid(context['operationId']) or not codec.valid_uuid(context['profileId'])
            or not binding.owner.hash_value(context['bindingRevision']) or type(context['replaceAccount']) is not bool):
        raise ValueError('invalid login operation')


def validate_result(result,context):
    if not isinstance(result,dict) or set(result)!={'status','challenge','binding'}:
        raise ValueError('invalid login result')
    status=result['status']
    if not isinstance(status,str) or status not in STATES:raise ValueError('invalid login status')
    challenge=result['challenge'];record=result['binding']
    if status=='login-required':
        if (not isinstance(challenge,dict) or set(challenge)!={'type','loginId','verificationUrl','userCode'}
                or challenge['type']!='chatgptDeviceCode' or not codec.valid_uuid(challenge['loginId'])
                or challenge['verificationUrl']!='https://auth.openai.com/codex/device'
                or not isinstance(challenge['userCode'],str) or not re.fullmatch('[A-Z0-9-]{4,32}',challenge['userCode'])):
            raise ValueError('invalid login challenge')
    elif challenge is not None:raise ValueError('unexpected login challenge')
    if status=='completed':
        binding.validate(record,context['profileId'])
        if record['owner']!=context['owner'] or record['grantId']==context['grantId']:
            raise ValueError('invalid replacement owner')
        if not context['replaceAccount'] and record['accountHash']!=context['accountHash']:
            raise ValueError('replacement account was not authorized')
    elif record is not None:raise ValueError('unexpected login binding')


def sign(context,result,key,deadline):
    try:
        context=codec.decode_json(codec.canonical(context));result=codec.decode_json(codec.canonical(result))
        validate_context(context);validate_result(result,context)
        if codec.public_identity(Path(str(key)+'.pub').read_bytes())[0]!=context['owner']:
            raise ValueError('wrong owner signing key')
        raw=codec.canonical({'context':context,'result':result})
        if len(raw)>MAX_BYTES or not math.isfinite(deadline) or deadline<=time.monotonic():
            raise ValueError('expired login response')
        signature=subprocess.run(['ssh-keygen','-Y','sign','-q','-f',str(key),'-n',NAMESPACE],
            input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=deadline-time.monotonic(),check=True).stdout
        if len(signature)>4096 or time.monotonic()>=deadline:raise ValueError('invalid signature')
        validate_context(context)
        return codec.canonical({'payload':base64.b64encode(raw).decode(),'signature':base64.b64encode(signature).decode()})
    except Exception:raise ValueError('login response could not be signed') from None


class Verifier:
    def __init__(self,context,public_key,deadline):
        self.context=codec.decode_json(codec.canonical(context));validate_context(self.context)
        identity,self.key=codec.public_identity(public_key)
        if identity!=self.context['owner'] or not math.isfinite(deadline) or deadline<=time.monotonic():
            raise ValueError('invalid login verifier')
        self.deadline=deadline;self.used=False;self.lock=threading.Lock()

    def verify(self,response):
        try:
            with self.lock:
                if self.used:raise ValueError('login response consumed')
                self.used=True
            validate_context(self.context)
            if not isinstance(response,bytes) or len(response)>2*MAX_BYTES or time.monotonic()>=self.deadline:
                raise ValueError('invalid login response size')
            envelope=codec.decode_json(response)
            if not isinstance(envelope,dict) or set(envelope)!={'payload','signature'}:raise ValueError('invalid envelope')
            raw=base64.b64decode(envelope['payload'],validate=True)
            signature=base64.b64decode(envelope['signature'],validate=True)
            if len(raw)>MAX_BYTES or not 0<len(signature)<=4096:raise ValueError('oversized login response')
            with tempfile.TemporaryDirectory(prefix='n2-login-verify-') as directory:
                sig=Path(directory)/'signature';signers=Path(directory)/'signers'
                sig.write_bytes(codec.public_signature(signature,self.key,NAMESPACE))
                signers.write_bytes(self.context['owner'].encode()+b' '+self.key+b'\n')
                subprocess.run(['ssh-keygen','-Y','verify','-f',str(signers),'-I',self.context['owner'],
                                '-n',NAMESPACE,'-s',str(sig)],input=raw,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                               timeout=max(.001,self.deadline-time.monotonic()),check=True)
            validate_context(self.context)
            if time.monotonic()>=self.deadline:raise ValueError('expired login verification')
            payload=codec.decode_json(raw)
            if not isinstance(payload,dict) or set(payload)!={'context','result'} or payload['context']!=self.context:
                raise ValueError('login response belongs to another request')
            validate_context(payload['context'])
            validate_result(payload['result'],self.context)
            return payload['result']
        except Exception:raise ValueError('login response rejected') from None
