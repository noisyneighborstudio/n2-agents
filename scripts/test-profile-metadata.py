#!/usr/bin/env python3
import base64
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('metadata', ROOT / 'profile-metadata.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profile = self.root / 'Work'; self.profile.mkdir()

    def test_stable_across_reads_and_rename_but_not_recreation(self):
        original = m.ensure(self.profile)
        self.assertEqual(m.ensure(self.profile), original)
        renamed = self.root / 'Renamed'; self.profile.rename(renamed)
        self.assertEqual(m.ensure(renamed), original)
        self.profile.mkdir()
        self.assertNotEqual(m.ensure(self.profile), original)

    def test_read_only_reporting_preserves_missing_and_legacy(self):
        self.assertEqual(m.report(self.root, '')['profiles'][1]['metadataStatus'], 'missing')
        self.assertFalse((self.profile / m.MARKER).exists())
        (self.profile / m.MARKER).write_bytes(m.LEGACY)
        self.assertEqual(m.report(self.root, '')['profiles'][1]['metadataStatus'], 'legacy')
        self.assertEqual((self.profile / m.MARKER).read_bytes(), m.LEGACY)
        self.assertIsNone(m.ensure(self.profile))
        self.assertEqual((self.profile / m.MARKER).read_bytes(), m.LEGACY)
        self.assertIsNotNone(m.ensure(self.profile, migrate_legacy=True)['profileId'])

    def test_invalid_schemas_links_and_nonregular_files_stay_untouched(self):
        path = self.profile / m.MARKER
        for raw in (b'bad', b'{"schemaVersion":2,"profileId":"anything"}', b'x' * 5000):
            path.write_bytes(raw)
            with self.assertRaises((ValueError, OSError)): m.ensure(self.profile)
            self.assertEqual(path.read_bytes(), raw)
        path.unlink()
        target = self.root / 'elsewhere'; target.write_bytes(m.LEGACY)
        path.symlink_to(target)
        with self.assertRaises(OSError): m.ensure(self.profile)
        self.assertTrue(path.is_symlink()); self.assertEqual(target.read_bytes(), m.LEGACY)
        path.unlink(); os.mkfifo(path)
        with self.assertRaises(ValueError): m.ensure(self.profile)

    def test_duplicate_ids_and_conflicts_are_unusable(self):
        original = m.ensure(self.profile)
        duplicate = self.root / 'Copy'; duplicate.mkdir()
        (duplicate / m.MARKER).write_text(json.dumps(original))
        rows = m.report(self.root, 'machine')['profiles']
        self.assertEqual([r['metadataStatus'] for r in rows if r['profileId']], ['duplicate', 'duplicate'])
        (duplicate / m.MARKER).unlink(); duplicate.rmdir()
        addr = 'profile|Work|-|.n2-profile'
        conflict = self.root / 'fleet/sync/conflicts' / m.hashlib.sha256(addr.encode()).hexdigest()[:12]
        conflict.mkdir(parents=True)
        self.assertEqual(m.report(self.root, 'machine')['profiles'][1]['metadataStatus'], 'conflicting')

    def test_rejected_child_write_preserves_existing_conflict(self):
        m.ensure(self.profile)
        script = r"""
        scripts_dir=$1; root=$2
        . "$scripts_dir/fleet.sh"; . "$scripts_dir/fleet-sync.sh"
        config_dir() { echo "$root/$1/$2"; }
        sync_init
        mkdir -p "$root/Work/codex"
        target="$root/Work/codex/config.toml"
        addr='settings|Work|codex|config.toml'
        printf ORIGINAL > "$target"
        sync_base_set owner "$addr" "$(sync_digest_file "$target")"
        printf LOCAL > "$target"
        local_digest=$(sync_digest_file "$target")
        printf REMOTE > "$root/candidate"
        [ "$(sync_absorb "$addr" "$root/candidate" "$(sync_digest_file "$root/candidate")" owner '')" = conflict ] || exit 1
        printf invalid > "$root/Work/.n2-profile"
        printf RESOLVED > "$root/candidate"
        sync_absorb "$addr" "$root/candidate" "$(sync_digest_file "$root/candidate")" owner "$local_digest" && exit 2
        sync_conflict_pinned "$addr" || exit 3
        [ "$(cat "$target")" = LOCAL ] || exit 4
        """
        subprocess.run(['sh', '-c', script, 'fixture', str(ROOT), str(self.root)],
                       check=True, capture_output=True, text=True)

    def test_actual_signed_replication_and_distinct_defaults(self):
        def call(peer, *args):
            home = self.root / peer; home.mkdir(exist_ok=True)
            env = dict(os.environ, HOME=str(home), N2_FLEET_AGENTS=str(ROOT / 'agents'))
            env.pop('N2_AGENTS_ROOT', None)
            return subprocess.check_output([str(ROOT / 'agents'), *args], env=env, text=True, stderr=subprocess.PIPE)
        a = call('a', 'fleet', 'init', '--machine', 'a').split()[1]
        b = call('b', 'fleet', 'init', '--machine', 'b').split()[1]
        code = call('a', 'fleet', 'invite', '--peer', b).strip()
        call('b', 'fleet', 'pair', '--home', str(self.root / 'a'), '--code', code)
        profile = self.root / 'a/.n2-agents/Team'; profile.mkdir()
        call('a', 'profiles', '--ensure-ids'); call('b', 'profiles', '--ensure-ids')
        before = json.loads(call('a', 'profiles', '--json'))
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _: call('a', 'profiles', '--ensure-ids'), range(8)))
        self.assertEqual(json.loads(call('a', 'profiles', '--json')), before)
        call('a', 'fleet', 'sync', 'now', '--peer', b)
        after = json.loads(call('b', 'profiles', '--json'))
        pick = lambda value, name: next(row for row in value['profiles'] if row['name'] == name)
        self.assertEqual(pick(before, 'Team')['profileId'], pick(after, 'Team')['profileId'])
        self.assertEqual(pick(after, 'Team')['metadataStatus'], 'ready')
        self.assertNotEqual(pick(before, 'Default')['profileId'], pick(after, 'Default')['profileId'])
        self.assertEqual(pick(after, 'Default')['scope'], 'machine-local')
        self.assertNotIn('profile|Default', call('a', 'fleet', 'sync', 'scope'))
        # Validation is enforced on a signed incoming offer, not just local reads.
        raw = b'{"schemaVersion":99,"profileId":"unsupported"}'
        payload = self.root / 'invalid-offer'
        payload.write_text('addr=profile|Invalid|-|.n2-profile\ndigest=' + m.hashlib.sha256(raw).hexdigest()
                           + '\nbase=\n--\n' + base64.b64encode(raw).decode() + '\n')
        try:
            call('a', 'fleet', 'send', b, '--verb', 'sync-put', '--payload-file', str(payload))
        except subprocess.CalledProcessError:
            pass
        self.assertFalse((self.root / 'b/.n2-agents/Invalid/.n2-profile').exists())
        # A previously converged legacy marker does not fork into two IDs just
        # because both peers upgrade. One explicit initialization propagates.
        for peer in ('a', 'b'):
            legacy = self.root / peer / '.n2-agents/Legacy'
            legacy.mkdir(); (legacy / m.MARKER).write_bytes(m.LEGACY)
        call('a', 'fleet', 'sync', 'now', '--peer', b)
        for peer in ('a', 'b'):
            self.assertEqual(pick(json.loads(call(peer, 'profiles', '--json')), 'Legacy')['metadataStatus'], 'legacy')
        call('a', 'profiles', '--ensure-ids')
        call('a', 'fleet', 'sync', 'now', '--peer', b)
        legacy_a = pick(json.loads(call('a', 'profiles', '--json')), 'Legacy')
        legacy_b = pick(json.loads(call('b', 'profiles', '--json')), 'Legacy')
        self.assertEqual(legacy_a['profileId'], legacy_b['profileId'])
        self.assertEqual(legacy_b['metadataStatus'], 'ready')
        # Child-first/interrupted old-protocol offers cannot make the receiver
        # invent an ID. The normal pass establishes metadata, then sends auth.
        for peer in ('a', 'b'):
            call(peer, 'fleet', 'sync', 'auth', 'enable', 'codex')
        slot = self.root / 'a/.n2-agents/Partial/codex'; slot.mkdir(parents=True)
        raw = b'{"tokens":{"access_token":"synthetic-only"}}'
        (slot / 'auth.json').write_bytes(raw)
        call('a', 'profiles', '--ensure-ids')
        payload.write_text('addr=auth|Partial|codex|auth.json\ndigest=' + m.hashlib.sha256(raw).hexdigest()
                           + '\nbase=\n--\n' + base64.b64encode(raw).decode() + '\n')
        try:
            call('a', 'fleet', 'send', b, '--verb', 'sync-put', '--payload-file', str(payload))
        except subprocess.CalledProcessError:
            pass
        self.assertFalse((self.root / 'b/.n2-agents/Partial').exists())
        call('b', 'fleet', 'sync', 'scope')
        call('a', 'fleet', 'sync', 'now', '--peer', b)
        self.assertEqual((self.root / 'b/.n2-agents/Partial/codex/auth.json').read_bytes(), raw)
        partial_a = pick(json.loads(call('a', 'profiles', '--json')), 'Partial')
        partial_b = pick(json.loads(call('b', 'profiles', '--json')), 'Partial')
        self.assertEqual(partial_a['profileId'], partial_b['profileId'])
        self.assertEqual(partial_b['metadataStatus'], 'ready')
        # Same display names created independently are not an identity match.
        for peer in ('a', 'b'):
            (self.root / peer / '.n2-agents/Independent').mkdir()
            call(peer, 'profiles', '--ensure-ids')
        call('a', 'fleet', 'sync', 'now', '--peer', b)
        rows = json.loads(call('a', 'profiles', '--json'))
        self.assertEqual(pick(rows, 'Independent')['metadataStatus'], 'conflicting')

if __name__ == '__main__': unittest.main()
