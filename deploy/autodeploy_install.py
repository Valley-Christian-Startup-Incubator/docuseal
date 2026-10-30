#!/usr/bin/env python3
"""Install DocuSeal watcher/proxy as isolated launchd jobs; run on valley-big-mac.

Create private ROOT/config.json and a clean canonical master clone first. This helper
never changes the tunnel or the original production Compose service. The caller
must transition ingress to the prepared proxy before enabling automatic rollouts.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

spec = importlib.util.spec_from_file_location('deployer', Path(__file__).with_name('autodeploy.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=m.ROOT)
    parser.add_argument('--caddy', default='/opt/homebrew/bin/caddy')
    parser.add_argument('--enable-watcher', action='store_true',
                        help='Only use after proxy and public ingress have been verified')
    args = parser.parse_args()
    if os.getuid() != 501:
        raise SystemExit('Expected Big Mac service account uid 501')
    root = args.root.resolve()
    with m.locked(root):
        deployer = m.Deployer(root)
        deployer.check_owner()
        deployer.probe(deployer.state['active']['port'])
        shutil.copyfile(Path(__file__).with_name('autodeploy.py'), root / 'autodeploy.py.next')
        os.replace(root / 'autodeploy.py.next', root / 'autodeploy.py')
        deployer.initialize_original()
        deployer.publish_assets(deployer.state['active']['container'])
        if not (root / 'proxy.json').exists():
            m.atomic(root / 'proxy.json', m.proxy_config(root, deployer.state['active']['port']))
        deployer.save()
        (root / 'logs').mkdir(exist_ok=True)
        agents = Path.home() / 'Library/LaunchAgents'
        agents.mkdir(parents=True, exist_ok=True)
        jobs = [('com.incubator.docuseal.proxy', [args.caddy, 'run', '--config', str(root / 'proxy.json')],
                 {'KeepAlive': True})]
        if args.enable_watcher:
            jobs.append(('com.incubator.docuseal.autodeploy',
                         [sys.executable, str(root / 'autodeploy.py'), '--root', str(root), '--once'],
                         {'StartInterval': 60}))
        for label, command, extra in jobs:
            path = agents / (label + '.plist')
            value = {'Label': label, 'ProgramArguments': command, 'RunAtLoad': True,
                     'LimitLoadToSessionType': 'Background',
                     'WorkingDirectory': str(root),
                     'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'},
                     'StandardOutPath': str(root / 'logs' / (label + '.out.log')),
                     'StandardErrorPath': str(root / 'logs' / (label + '.err.log')), **extra}
            # Preserve an existing proxy process and its connections. Watcher update is locked.
            loaded = subprocess.run(['launchctl', 'print', 'user/501/' + label],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if loaded and label.endswith('.proxy'):
                continue
            if loaded:
                subprocess.run(['launchctl', 'bootout', 'user/501/' + label], check=True)
            with open(path, 'wb') as output:
                plistlib.dump(value, output)
            os.chmod(path, 0o600)
            subprocess.run(['launchctl', 'bootstrap', 'user/501', str(path)], check=True)
    print('Prepared dedicated DocuSeal proxy' + (' and 60-second watcher' if args.enable_watcher else ''))


if __name__ == '__main__':
    main()
