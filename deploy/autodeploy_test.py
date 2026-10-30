#!/usr/bin/env python3
"""Isolated deployer tests. Set CADDY_BIN for real graceful proxy continuity test."""
import concurrent.futures
import contextlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.request
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('deployer', Path(__file__).with_name('autodeploy.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.d = m.Deployer(self.root)
        self.release = {'sha': 'a' * 40, 'port': 3040, 'container': 'isolated-test'}

    def tearDown(self):
        self.temp.cleanup()

    def test_nonblocking_lock(self):
        with m.locked(self.root):
            with self.assertRaises(BlockingIOError):
                with m.locked(self.root):
                    self.fail('Second writer entered')
        with m.locked(self.root):
            pass

    def test_failed_build_keeps_active_and_skips_same_sha(self):
        original = self.d.state['active'].copy()
        with patch.object(self.d, 'recover'), patch.object(self.d, 'collect'), patch.object(self.d, 'check_owner'), \
             patch.object(self.d, 'fetch', return_value=self.release['sha']), \
             patch.object(self.d, 'build', side_effect=RuntimeError('fixture build failure')) as build:
            with self.assertRaises(RuntimeError):
                self.d.once()
            self.assertEqual(self.d.state['active'], original)
            self.assertEqual(self.d.state['failed_sha'], self.release['sha'])
            self.d.once()
            self.assertEqual(build.call_count, 1)
            with self.assertRaises(RuntimeError):
                self.d.once(retry=True)
            self.assertEqual(build.call_count, 2)

    def test_failed_public_switch_returns_to_old_upstream(self):
        original = self.d.state['active'].copy()
        self.d.config['public_health_url'] = 'http://fixture.invalid/up'
        with patch.object(self.d, 'app_check'), patch.object(self.d, 'publish_assets'), \
             patch.object(self.d, 'probe'), patch.object(self.d, 'switch') as switch, \
             patch.object(self.d, 'run', side_effect=RuntimeError('public failure')):
            with self.assertRaises(RuntimeError):
                self.d.rollout(self.release)
        self.assertEqual([x.args[0] for x in switch.call_args_list], [self.release, original])
        self.assertEqual(self.d.state['active'], original)
        self.assertFalse((self.root / 'transaction.json').exists())

    def test_interrupted_switch_recovers_durable_release(self):
        m.atomic(self.root / 'transaction.json', {'to': self.release})
        with patch.object(self.d, 'switch') as switch, patch.object(self.d, 'probe'):
            self.d.recover()
        switch.assert_called_once_with(self.d.state['active'])
        self.assertFalse((self.root / 'transaction.json').exists())

    def test_never_collect_active_previous_or_original(self):
        old = {'sha': 'b' * 40, 'port': 3041, 'container': 'older-managed'}
        self.d.state['previous'] = self.release
        self.d.state['releases'] = [self.release, old]
        with patch.object(self.d, 'drained', return_value=True), patch.object(self.d, 'docker', return_value='isolated-test\nolder-managed\n') as docker:
            self.d.collect()
        self.assertEqual(self.d.state['releases'], [self.release])
        self.assertEqual(docker.call_args_list[1].args, ('stop', '--time', '-1', 'older-managed'))

    def test_cap_and_reserved_admin_port(self):
        self.d.state['releases'] = [self.release] * 4
        with self.assertRaisesRegex(RuntimeError, 'Four managed'):
            self.d.build('c' * 40)

    def test_atomic_assets_retained_and_collision_refused(self):
        builds = []
        def fixture_copy(*args):
            target = Path(args[-1])
            target.mkdir()
            (target / 'app-a1.js').write_text('old client')
            builds.append(1)
            for name in ['manifest.json', 'manifest.json.gz', 'manifest.json.br']:
                (target / name).write_text(str(len(builds)))
        with patch.object(self.d, 'docker', side_effect=fixture_copy):
            self.d.publish_assets('fixture')
            self.d.publish_assets('fixture')
        self.assertEqual((self.root / 'assets/packs/app-a1.js').read_text(), 'old client')
        for name in ['manifest.json', 'manifest.json.gz', 'manifest.json.br']:
            self.assertFalse((self.root / 'assets/packs' / name).exists())
        (self.root / 'assets/packs/app-a1.js').write_text('collision')
        with patch.object(self.d, 'docker', side_effect=fixture_copy), self.assertRaises(RuntimeError):
            self.d.publish_assets('fixture')


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@unittest.skipUnless(os.environ.get('CADDY_BIN'), 'Set CADDY_BIN for real isolated Caddy test')
class ProxyContinuity(unittest.TestCase):
    def test_inflight_request_and_retained_asset(self):
        entered, finish = threading.Event(), threading.Event()
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/slow':
                    entered.set()
                    finish.wait(10)
                body = (self.headers.get('X-Forwarded-Proto', '') if self.path == '/forwarded'
                        else self.server.label).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args):
                pass
        servers = []
        process = None
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            admin, listener = free_port(), free_port()
            for label in ['old', 'new']:
                server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
                server.label = label
                threading.Thread(target=server.serve_forever, daemon=True).start()
                servers.append(server)
            def config(port):
                result = m.proxy_config(root, port)
                result['admin']['listen'] = '127.0.0.1:' + str(admin)
                result['apps']['http']['servers']['docuseal']['listen'] = ['127.0.0.1:' + str(listener)]
                return result
            (root / 'assets/packs').mkdir(parents=True)
            (root / 'assets/packs/old-client-hash.js').write_text('retained')
            m.atomic(root / 'proxy.json', config(servers[0].server_port))
            try:
                process = subprocess.Popen([os.environ['CADDY_BIN'], 'run', '--config', str(root / 'proxy.json')],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for attempt in range(100):
                    try:
                        urllib.request.urlopen('http://127.0.0.1:%s/config/' % admin, timeout=.2).close()
                        break
                    except Exception:
                        time.sleep(.05)
                def get(path):
                    with urllib.request.urlopen('http://127.0.0.1:%s%s' % (listener, path), timeout=15) as response:
                        return response.read()
                with concurrent.futures.ThreadPoolExecutor() as executor:
                    slow = executor.submit(get, '/slow')
                    self.assertTrue(entered.wait(5))
                    request = urllib.request.Request('http://127.0.0.1:%s/load' % admin,
                        data=json.dumps(config(servers[1].server_port)).encode(),
                        headers={'Content-Type': 'application/json'}, method='POST')
                    with urllib.request.urlopen(request, timeout=5):
                        pass
                    self.assertEqual(get('/'), b'new')
                    self.assertEqual(get('/forwarded'), b'https')
                    self.assertEqual(get('/packs/old-client-hash.js'), b'retained')
                    finish.set()
                    self.assertEqual(slow.result(timeout=5), b'old')
            finally:
                finish.set()
                if process:
                    process.terminate()
                    process.wait(timeout=5)
                for server in servers:
                    server.shutdown()
                    server.server_close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
