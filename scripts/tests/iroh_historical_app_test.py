#!/usr/bin/env python3
"""Production HTTP acceptance against frozen 0.98.2 and current application code.

Only fixture role/capacity setup and post-stop persistence inspection use the
small Rust example. Every transfer, authorization, eviction, and restoration
runs through the actual daemon API. No wire implementation is copied here.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(os.environ['PHOTO_ORGANIZER_IROH_APP_TEST_ROOT']).resolve(strict=True)
REPO = Path(os.environ['IROH_APP_REPO']).resolve(strict=True)
CURRENT = Path(os.environ['IROH_APP_CURRENT_BIN']).resolve(strict=True)
HISTORICAL = Path(os.environ['IROH_APP_HISTORICAL_BIN']).resolve(strict=True)
CURRENT_FIXTURE = Path(os.environ['IROH_APP_CURRENT_FIXTURE_BIN']).resolve(strict=True)
HISTORICAL_FIXTURE = Path(os.environ['IROH_APP_HISTORICAL_FIXTURE_BIN']).resolve(strict=True)
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def terminate(signum, _frame):
    # Raising through the coordinator runs scenario's finally block, which
    # stops every detached daemon group before the shell removes test data.
    # Ignore repeat termination while cleanup waits for those processes.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)


class Node:
    def __init__(self, root, binary, dbus_address):
        self.root, self.binary = root, binary
        root.mkdir(parents=True)
        for directory in (root / 'home' / 'data', root / 'run', root / 'tmp'):
            directory.mkdir(parents=True, exist_ok=True)
        (root / 'run').chmod(0o700)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        self.env = os.environ.copy()
        # Never inherit a developer's backend, daemon bind, keyring or library.
        for name in list(self.env):
            if name.startswith('PRIVATE_GALLERY_'):
                self.env.pop(name)
        # The explicit test D-Bus address below is the only allowed keyring
        # route. Do not let desktop-session control sockets or XDG locations
        # point the Rust secure-storage client at the developer's session.
        self.env.pop('GNOME_KEYRING_CONTROL', None)
        self.env.update({
            'IROH_APP_NODE_ROOT': str(root),
            'PRIVATE_GALLERY_RUNTIME_ROOT': str(root / 'runtime'),
            'PRIVATE_GALLERY_LIBRARY_ROOT': str(root / 'library'),
            'PRIVATE_GALLERY_BIND_HOST': '127.0.0.1',
            'PRIVATE_GALLERY_BIND_PORT': str(self.port),
            'PRIVATE_GALLERY_NETWORK_POLICY': 'offline_only',
            'RUST_LOG': 'warn',
            # This is a test-created D-Bus service whose Unix socket is under
            # the harness root. It never inherits the developer's keyring.
            'DBUS_SESSION_BUS_ADDRESS': dbus_address,
            'HOME': str(root / 'home'),
            'XDG_DATA_HOME': str(root / 'home' / 'data'),
            'XDG_RUNTIME_DIR': str(root / 'run'),
            'TMPDIR': str(root / 'tmp'),
        })
        self.process = None
        self.log = None

    def command(self, binary, *args):
        return [str(binary), *args]

    def start(self):
        assert self.process is None
        self.log = (self.root / 'daemon.log').open('ab')
        self.process = subprocess.Popen(self.command(self.binary), env=self.env,
                                        stdout=self.log, stderr=self.log,
                                        start_new_session=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AssertionError(f'daemon exited; diagnostic log: {self.root / "daemon.log"}')
            try:
                self.api('/health')
                return
            except (OSError, urllib.error.URLError):
                time.sleep(0.1)
        raise AssertionError('daemon did not become healthy within 30 seconds')

    def stop(self):
        if self.process is None:
            return
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
            raise AssertionError('daemon session did not stop within 10 seconds')
        finally:
            self.process = None
            self.log.close()
            self.log = None

    def api(self, path, payload=None, *, raw=False):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}{path}',
                                         data=data, headers={'Content-Type': 'application/json'})
        try:
            with HTTP.open(request, timeout=30) as response:
                value = response.read()
        except urllib.error.HTTPError as error:
            error.add_note(f'{path}: {error.read().decode(errors="replace")}')
            raise
        return value if raw else json.loads(value)

    def fixture(self, operation):
        assert self.process is None, 'never open a live daemon database externally'
        fixture = HISTORICAL_FIXTURE if self.binary == HISTORICAL else CURRENT_FIXTURE
        result = subprocess.run(self.command(fixture, operation), env=self.env,
                                check=False, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30)
        if result.returncode:
            raise AssertionError(f'fixture {operation} failed: {result.stderr.decode(errors="replace")}')
        return json.loads(result.stdout) if operation == 'inspect' else None

    def endpoint(self):
        descriptor = self.api('/sync/network/local-endpoint')['descriptor']
        assert descriptor['relay_urls'] == []
        assert descriptor['direct_addresses'], 'namespace endpoint must advertise a direct address'
        return descriptor

    def settings(self):
        self.api('/library/settings', {'library_root': str(self.root / 'library'),
                                      'default_import_mode': 'copy',
                                      'original_storage_policy': 'encrypted_only'})


def enroll(local, descriptor, vault_id):
    return local.api('/devices/enroll', {
        'display_name': descriptor['device_name'], 'platform': descriptor['platform'],
        'public_key': descriptor['node_id'], 'vault_id': vault_id,
        'role': descriptor['role'], 'trust_level': descriptor['trust_level'],
        'storage_profile': {'device_id': None, 'total_bytes': None,
                            'available_bytes': None, 'reserved_bytes': 0,
                            'accepts_storage': True, 'battery_powered': False,
                            'metered_network': False, 'low_battery': False},
        'endpoint': descriptor,
    })


def completed_sync(node, vault_id, size):
    plan = node.api('/sync/run', {'vault_id': vault_id, 'dry_run': False})
    results = plan['execution_results']
    assert len(results) == 1 and results[0]['status'] == 'completed', results
    assert results[0]['bytes_transferred'] == size, results
    return results[0]


def persisted_proof(snapshot, blob_id, device_id):
    replicas = [r for r in snapshot['replicas']
                if r['blob_id'] == blob_id and r['device_id'] == device_id]
    assert len(replicas) == 1 and replicas[0]['health'] == 'healthy', replicas
    replica = replicas[0]
    assert replica['verified_at'] and replica['transfer_id'], replica
    assert any(t['id'] == replica['transfer_id'] and t['status'] == 'completed'
               and t['bytes_completed'] == t['bytes_total']
               for t in snapshot['transfers']), 'replica requires persisted completed transfer proof'


def verified_chunks(node, snapshot):
    hashes = []
    for chunk in snapshot['chunks']:
        relative = Path(chunk['local_path'])
        assert not relative.is_absolute() and '..' not in relative.parts
        encrypted = (node.root / 'library' / relative).read_bytes()
        digest = hashlib.sha256(encrypted).hexdigest()
        assert digest == chunk['encrypted_hash']
        assert len(encrypted) == chunk['encrypted_bytes']
        hashes.append((chunk['chunk_index'], digest))
    assert hashes
    return sorted(hashes)


def scenario(label, source_binary, receiver_binary):
    source = Node(ROOT / label / 'source', source_binary,
                  os.environ['IROH_APP_SOURCE_DBUS_ADDRESS'])
    receiver = Node(ROOT / label / 'receiver', receiver_binary,
                    os.environ['IROH_APP_RECEIVER_DBUS_ADDRESS'])
    nodes = [source, receiver]
    try:
        source.start()
        receiver.start()
        source.settings()
        receiver.settings()
        vault = source.api('/vaults')[0]
        policy = dict(vault['storage_policy'], mode='custom', min_replicas=2,
                      min_free_space_bytes=0, allow_metered_network=True,
                      pause_on_low_battery=False)
        source.api(f'/vaults/{vault["id"]}/storage-policy', {'policy': policy})
        receiver.api('/vaults', {'id': vault['id'], 'name': vault['name'],
                                'storage_policy': policy})
        for node, role in [(source, 'contributor'), (receiver, 'storage-only')]:
            node.stop()
            node.fixture(f'setup-{role}')
            node.start()
        source_endpoint, receiver_endpoint = source.endpoint(), receiver.endpoint()
        assert receiver_endpoint['trust_level'] == 'storage_only'
        enroll(source, receiver_endpoint, vault['id'])
        enroll(receiver, source_endpoint, vault['id'])
        # Fixed, non-personal input; AEAD ciphertext is generated by the real import.
        original = b'Photo Organizer historical Iroh application acceptance\n' * 4096
        path = source.root / 'source.jpg'
        path.write_bytes(original)
        imported = source.api(f'/vaults/{vault["id"]}/imports/assets', {
            'source_path': str(path), 'original_filename': 'source.jpg',
            'media_kind': 'photo', 'mime_type': 'image/jpeg', 'bytes': len(original),
            'import_mode': 'copy',
        })
        asset_id = imported['asset']['id']
        assert source.api(f'/assets/{asset_id}/original', raw=True) == original
        try:
            source.api(f'/assets/{asset_id}/evict-local', {})
        except urllib.error.HTTPError as error:
            assert error.code in (400, 409), error.code
        else:
            raise AssertionError('eviction succeeded before completed remote proof')
        pushed = completed_sync(source, vault['id'], len(original))
        key_path = source.root / 'runtime/identity/iroh_endpoint.key'
        identity_key = key_path.read_bytes()  # Test-created key; never printed.
        source.stop()
        pushed_state = source.fixture('inspect')
        blob_id = pushed['blob_id']
        persisted_proof(pushed_state, blob_id, receiver_endpoint['device_id'])
        source_hashes = verified_chunks(source, pushed_state)
        source.start()
        assert key_path.read_bytes() == identity_key
        restarted = source.endpoint()
        assert restarted['node_id'] == source_endpoint['node_id']
        assert restarted['device_id'] == source_endpoint['device_id']
        # The receiver stays live. Pull authenticates the restarted requester's
        # existing node identity, independent of its newly chosen local UDP port.
        policy['min_replicas'] = 1
        source.api(f'/vaults/{vault["id"]}/storage-policy', {'policy': policy})
        evicted = source.api(f'/assets/{asset_id}/evict-local', {})
        assert evicted['state'] == 'remote_available' and not evicted['local_replica']
        for chunk in pushed_state['chunks']:
            assert not (source.root / 'library' / chunk['local_path']).exists()
        pending = source.api(f'/assets/{asset_id}/pin-local', {})
        assert pending['state'] == 'transfer_pending'
        pulled = completed_sync(source, vault['id'], len(original))
        assert pulled['from_device_id'] == receiver_endpoint['device_id']
        assert source.api(f'/assets/{asset_id}/original', raw=True) == original
        assert source.api(f'/assets/{asset_id}/availability')['state'] == 'local_available'
        source.stop()
        receiver.stop()
        source_state, receiver_state = source.fixture('inspect'), receiver.fixture('inspect')
        persisted_proof(source_state, blob_id, source_endpoint['device_id'])
        persisted_proof(receiver_state, blob_id, receiver_endpoint['device_id'])
        assert verified_chunks(source, source_state) == source_hashes
        assert verified_chunks(receiver, receiver_state) == source_hashes
        assert receiver_state['asset_count'] == 0
        assert all(c['content_hash'].startswith('opaque:') and c['nonce_hex'] is None
                   and c['aad'] is None for c in receiver_state['chunks'])
        # Boot the historical node's existing, already enrolled runtime with the
        # current daemon. No re-enrollment, regenerated identity, or file key backend.
        historical = source if source_binary == HISTORICAL else receiver
        previous = source_endpoint if historical is source else receiver_endpoint
        old_key = (historical.root / 'runtime/identity/iroh_endpoint.key').read_bytes()
        historical.binary = CURRENT
        historical.start()
        upgraded = historical.endpoint()
        assert upgraded['node_id'] == previous['node_id']
        assert upgraded['device_id'] == previous['device_id']
        assert (historical.root / 'runtime/identity/iroh_endpoint.key').read_bytes() == old_key
        expected_peer = receiver_endpoint if historical is source else source_endpoint
        devices = historical.api('/devices')
        assert any(d['id'] == expected_peer['device_id'] and d['public_key'] == expected_peer['node_id']
                   and d['revoked_at'] is None for d in devices)
        if historical is source:
            assert historical.api(f'/assets/{asset_id}/original', raw=True) == original
        historical.stop()
        upgraded_state = historical.fixture('inspect')
        assert upgraded_state['transfers'] == (source_state if historical is source else receiver_state)['transfers']
        evidence = json.dumps({'case': label, 'verified': True, 'original_bytes': len(original),
                               'encrypted_chunks': len(source_hashes),
                               'historical_identity_preserved': True})
        with (ROOT / 'evidence.jsonl').open('a') as output:
            output.write(evidence + '\n')
        print(evidence, flush=True)
    finally:
        cleanup_error = None
        for node in nodes:
            try:
                node.stop()
            except Exception as error:
                if cleanup_error is None:
                    cleanup_error = error
                else:
                    cleanup_error.add_note(f'additional node cleanup failure: {error!r}')
        if cleanup_error is not None:
            active_error = sys.exception()
            if active_error is None:
                raise cleanup_error
            active_error.add_note(f'node cleanup failure after the primary error: {cleanup_error!r}')


if __name__ == '__main__':
    scenario('historical-source-current-receiver', HISTORICAL, CURRENT)
    scenario('current-source-historical-receiver', CURRENT, HISTORICAL)
