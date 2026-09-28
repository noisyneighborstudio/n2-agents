#!/usr/bin/env python3
"""Production native action through signed two-peer CLI fixtures."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native_transfer_fixture',ROOT/'scripts/test-fleet-session.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
BINARY=sys.argv.pop(1)

class NativeTransferTests(fixture.TransferTests):
    def setUp(self):
        super().setUp()
        alias=self.wire.base/"destination 'alias;$(not-a-command)"
        alias.symlink_to(self.cwd,target_is_directory=True);self.cwd=alias
    def send(self):
        return subprocess.run([BINARY,'--send',os.environ.get('N2_TEST_CLI',str(ROOT/'agents')),
            self.thread,self.wire.identities['owner'],str(self.cwd)],
            env=dict(os.environ,N2_AGENTS_ROOT=str(self.source)),capture_output=True,text=True,timeout=30)

if __name__=='__main__':
    unittest.main(defaultTest=['NativeTransferTests.test_signed_transfer_discovery_resume_and_original_account',
                              'NativeTransferTests.test_unapproved_sender_cannot_publish'])
