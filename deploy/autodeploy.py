#!/usr/bin/env python3
"""DocuSeal's isolated, outbound Big Mac release watcher (Python standard library)."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path.home() / '.local/share/docuseal/deploy'
OWNER = 'Valley-Christian-Startup-Incubator'
REPOSITORY = OWNER + '/docuseal'
URL = 'https://github.com/' + REPOSITORY


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    with open(temporary, 'w') as output:
        os.chmod(temporary, 0o600)
        json.dump(value, output, indent=2)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def read(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


@contextlib.contextmanager
def locked(root):
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    with open(root / 'deploy.lock', 'a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def proxy_config(root, port):
    return {'admin': {'listen': '127.0.0.1:3047', 'config': {'persist': False}},
            'apps': {'http': {'servers': {'docuseal': {
                'listen': ['127.0.0.1:3037'], 'routes': [
                    {'match': [{'path': ['/packs/*']}], 'handle': [
                        {'handler': 'file_server', 'root': str(root / 'assets')}]},
                    {'handle': [{'handler': 'reverse_proxy', 'headers': {'request': {'set': {
                            'X-Forwarded-Proto': ['https']}}}, 'upstreams': [
                        {'dial': '127.0.0.1:' + str(port)}]}]}]}}}}}


class Deployer:
    def __init__(self, root):
        self.root = root
        self.config = read(root / 'config.json', {})
        self.checkout = Path(self.config.get('source_checkout', str(root / 'source')))
        self.state = read(root / 'state.json', {'active': {'sha': 'original', 'port': 3035,
            'container': 'valley-docuseal-app-1'}, 'previous': None, 'releases': []})
        self.log = None

    def run(self, args, capture=True, cwd=None, timeout=1800):
        # Arguments and subprocess errors are never printed: environment contains secrets.
        result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE if capture else self.log,
                                stderr=self.log or subprocess.DEVNULL, timeout=timeout)
        if result.returncode:
            raise RuntimeError('Command failed: ' + Path(args[0]).name)
        return result.stdout.decode() if capture else ''

    def docker(self, *args, **kwargs):
        return self.run([self.config.get('docker', '/opt/homebrew/bin/docker'), *args], **kwargs)

    def initialize_original(self):
        if self.state['active']['sha'] == 'original':
            self.state['active']['sha'] = self.run(
                ['git', 'rev-parse', 'HEAD'], cwd=self.checkout).strip()

    def save(self):
        atomic(self.root / 'state.json', self.state)

    def check_owner(self):
        if self.config.get('full_name') != REPOSITORY or self.config.get('canonical_url') != URL:
            raise RuntimeError('Missing verified canonical repository configuration')
        request = urllib.request.Request('https://api.github.com/repos/' + REPOSITORY,
                                         headers={'Accept': 'application/vnd.github+json'})
        with urllib.request.urlopen(request, timeout=20) as response:
            repo = json.load(response)
        if (repo['owner']['login'].lower() != OWNER.lower() or repo['full_name'].lower() != REPOSITORY.lower()
                or repo['html_url'].lower().rstrip('/') != URL.lower()):
            raise RuntimeError('Repository ownership gate no longer passes')

    def fetch(self):
        if self.config.get('full_name') != REPOSITORY or self.config.get('canonical_url') != URL:
            raise RuntimeError('Missing verified canonical repository configuration')
        if self.run(['git', 'status', '--porcelain'], cwd=self.checkout).strip():
            raise RuntimeError('Deployment checkout is dirty')
        if self.run(['git', 'branch', '--show-current'], cwd=self.checkout).strip() != 'master':
            raise RuntimeError('Deployment checkout must be on master')
        self.run(['git', 'fetch', URL + '.git', 'master'], cwd=self.checkout)
        sha = self.run(['git', 'rev-parse', 'FETCH_HEAD'], cwd=self.checkout).strip()
        self.run(['git', 'merge-base', '--is-ancestor', 'HEAD', sha], cwd=self.checkout)
        self.run(['git', 'merge', '--ff-only', sha], cwd=self.checkout)
        return sha

    def probe(self, port, attempts=60):
        for attempt in range(attempts):
            try:
                for path in ['/up', '/sign_in']:
                    req = urllib.request.Request('http://127.0.0.1:%s%s' % (port, path),
                        headers={'Host': 'sign.valleychristianai.com', 'X-Forwarded-Proto': 'https'})
                    with urllib.request.urlopen(req, timeout=5) as response:
                        body = response.read().lower()
                        if response.geturl() != req.full_url or response.status != 200 or (path != '/up' and b'password' not in body):
                            raise RuntimeError('Application readiness failed')
                return
            except Exception:
                if attempt + 1 == attempts:
                    raise RuntimeError('Application readiness timed out') from None
                time.sleep(2)

    def app_check(self, release):
        self.probe(release['port'])
        self.docker('exec', '-w', '/app', release['container'], 'bundle', 'exec', 'rails', 'runner',
                    'raise "Database unavailable" unless ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1',
                    timeout=120)

    def publish_assets(self, container):
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            self.docker('cp', container + ':/app/public/packs', directory + '/packs')
            for source in Path(directory, 'packs').rglob('*'):
                if not source.is_file() or source.is_symlink():
                    continue
                relative = source.relative_to(directory)
                target = self.root / 'assets' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                # Manifest names are mutable and served by Rails. Hashed assets are retained forever.
                if source.suffix == '.json':
                    continue
                if target.exists():
                    if hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(source.read_bytes()).digest():
                        raise RuntimeError('Existing asset name has changed content: ' + str(relative))
                    continue
                temporary = target.with_name(target.name + '.publish')
                shutil.copyfile(source, temporary)
                os.chmod(temporary, 0o644)
                os.replace(temporary, target)

    def switch(self, release):
        config = proxy_config(self.root, release['port'])
        # Caddy /load gracefully replaces routes without terminating old requests.
        request = urllib.request.Request('http://127.0.0.1:3047/load',
            data=json.dumps(config).encode(), headers={'Content-Type': 'application/json'}, method='POST')
        with urllib.request.urlopen(request, timeout=20) as response:
            response.read()
        atomic(self.root / 'proxy.json', config)

    def recover(self):
        transaction = read(self.root / 'transaction.json')
        if transaction:
            # A switch with no durable commit always returns to the last durable active release.
            self.switch(self.state['active'])
            self.probe(3037)
            (self.root / 'transaction.json').unlink()

    def drained(self, release):
        try:
            counts = self.docker('exec', '-w', '/app', release['container'], 'bundle', 'exec', 'rails', 'runner',
                'require "sidekiq/api"; s = Sidekiq::Stats.new; '
                'tcp = ["/proc/net/tcp","/proc/net/tcp6"].select { |p| File.exist?(p) }; '
                'connections = tcp.empty? ? 1 : tcp.sum { |p| File.readlines(p).drop(1).count { |line| '
                'f = line.split; f[1].split(":").last == "0BB8" && f[3] == "01" } }; '
                'puts JSON.generate([s.enqueued,s.retry_size,s.scheduled_size,Sidekiq::WorkSet.new.size,connections])', timeout=120)
            return json.loads(counts.strip().splitlines()[-1]) == [0, 0, 0, 0, 0]
        except Exception:
            return False

    def collect(self):
        protected = {r['container'] for r in [self.state['active'], self.state['previous']] if r}
        # Never stop the original Compose service; only explicitly tracked managed releases.
        existing = set(self.docker('ps', '-a', '--format', '{{.Names}}').splitlines())
        for release in list(self.state['releases']):
            if release['container'] not in existing and release['container'] not in protected:
                self.state['releases'].remove(release)
                continue
            if release['container'] not in protected and self.drained(release):
                self.docker('stop', '--time', '-1', release['container'])
                self.docker('rm', release['container'])
                self.state['releases'].remove(release)
        self.save()

    def build(self, sha):
        if len(self.state['releases']) >= 4:
            raise RuntimeError('Four managed releases remain; wait for background queues to drain')
        used = {r['port'] for r in self.state['releases']}
        port = None
        for number in range(3040, 3051):
            if number == 3047 or number in used:
                continue
            with socket.socket() as sock:
                try:
                    sock.bind(('127.0.0.1', number))
                    port = number
                    break
                except OSError:
                    pass
        if port is None:
            raise RuntimeError('No free release port')
        release = {'sha': sha, 'port': port, 'container': 'docuseal-release-' + sha[:12]}
        image = 'docuseal-vcs:' + sha
        self.docker('build', '--build-arg', 'VCS_REVISION=' + sha, '-f', 'deploy/Dockerfile.vcs',
                    '-t', image, '.', capture=False, cwd=self.checkout)
        original = json.loads(self.docker('inspect', 'valley-docuseal-app-1'))[0]
        allowed = {'FORCE_SSL', 'DATABASE_URL', 'POSTGRES_PASSWORD', 'SECRET_KEY_BASE', 'HOST', 'APP_URL'}
        environment = [e for e in original['Config']['Env'] if e.split('=', 1)[0] in allowed]
        environment += ['RUN_MIGRATIONS=false', 'VCS_REDIS_WORKDIR=/data/docuseal/redis/' + sha]
        env_path = self.root / 'candidate.env'
        try:
            fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as output:
                output.write('\n'.join(environment) + '\n')
            # Persist allocation first, so an interrupted launch cannot leave an untracked worker.
            self.state['releases'].append(release)
            self.save()
            self.docker('run', '-d', '--name', release['container'], '--restart', 'unless-stopped',
                '--label', 'com.incubator.docuseal.release=' + sha,
                '--network', 'valley-docuseal_default', '-p', '127.0.0.1:%s:3000' % port,
                '--env-file', str(env_path), '-v', 'valley-docuseal_documents:/data/docuseal', image)
        finally:
            env_path.unlink(missing_ok=True)
        return release

    def rollout(self, release):
        self.app_check(release)
        self.publish_assets(release['container'])
        atomic(self.root / 'transaction.json', {'from': self.state['active'], 'to': release})
        old = self.state['active']
        try:
            self.switch(release)
            self.probe(3037)
            public = self.config.get('public_health_url')
            if not public:
                raise RuntimeError('public_health_url is required before cutover')
            # The public Cloudflare route accepts curl's established client profile;
            # Python urllib is denied by its bot rule even for healthy releases.
            response = self.run(['/usr/bin/curl', '--fail', '--silent', '--show-error',
                                 '--max-time', '15', '--write-out', '\n%{http_code}', public],
                                timeout=20)
            if response.rsplit('\n', 1)[-1] != '200':
                raise RuntimeError('Public readiness failed')
            self.state['previous'] = old
            self.state['active'] = release
            self.state.pop('failed_sha', None)
            self.save()
            (self.root / 'transaction.json').unlink()
        except Exception:
            self.switch(old)
            self.probe(3037)
            (self.root / 'transaction.json').unlink(missing_ok=True)
            raise

    def once(self, retry=False):
        self.recover()
        self.collect()
        if (self.root / 'paused').exists():
            return
        sha = self.fetch()
        if sha == self.state['active']['sha'] or (sha == self.state.get('failed_sha') and not retry):
            return
        path = self.root / 'logs' / (sha + '-' + str(int(time.time())) + '.log')
        path.parent.mkdir(exist_ok=True)
        with open(path, 'w') as self.log:
            os.chmod(path, 0o600)
            try:
                self.check_owner()
                release = next((r for r in self.state['releases'] if r['sha'] == sha), None)
                self.rollout(release or self.build(sha))
                # A running watcher stays pinned; replacement is only for its next invocation.
                shutil.copyfile(self.checkout / 'deploy/autodeploy.py', self.root / 'autodeploy.py.next')
                os.replace(self.root / 'autodeploy.py.next', self.root / 'autodeploy.py')
                print('DocuSeal deployed ' + sha)
            except Exception:
                self.state['failed_sha'] = sha
                self.save()
                raise
            finally:
                self.log = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    actions = parser.add_mutually_exclusive_group()
    for name in ['once', 'retry', 'status', 'rollback', 'pause', 'resume', 'init-proxy']:
        actions.add_argument('--' + name, action='store_true')
    args = parser.parse_args()
    if args.status:
        print(json.dumps({'paused': (args.root / 'paused').exists(),
            'state': read(args.root / 'state.json'), 'transaction': read(args.root / 'transaction.json')}, indent=2))
        return
    if args.pause:
        args.root.mkdir(parents=True, exist_ok=True)
        (args.root / 'paused').touch()
        return
    if args.resume:
        (args.root / 'paused').unlink(missing_ok=True)
        return
    try:
        with locked(args.root):
            deployer = Deployer(args.root)
            if args.init_proxy:
                deployer.initialize_original()
                deployer.publish_assets(deployer.state['active']['container'])
                atomic(args.root / 'proxy.json', proxy_config(args.root, deployer.state['active']['port']))
                deployer.save()
            elif args.rollback:
                deployer.recover()
                previous = deployer.state['previous']
                if not previous:
                    raise RuntimeError('No previous release')
                if previous['container'] == 'valley-docuseal-app-1':
                    atomic(args.root / 'transaction.json', {'from': deployer.state['active'], 'to': previous})
                    deployer.switch(previous)
                    deployer.probe(3037)
                    deployer.state['previous'], deployer.state['active'] = deployer.state['active'], previous
                    deployer.save()
                    (args.root / 'transaction.json').unlink()
                else:
                    deployer.rollout(previous)
                (args.root / 'paused').touch()
            else:
                deployer.once(args.retry)
    except BlockingIOError:
        return
    except Exception as error:
        print('DocuSeal deploy failed: ' + str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
