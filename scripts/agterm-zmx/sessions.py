#!/usr/bin/env python3
"""Terminal-only discovery and attachment to recorded remote sessions."""
import argparse
import json
import os
from pathlib import Path
import pwd
import subprocess

import host


def resolve(name):
    path = Path('/etc/agt-zmx-aliases.json')
    if path.exists():
        aliases = json.loads(path.read_text()).get(pwd.getpwuid(os.getuid()).pw_name, {})
        name = aliases.get(name, name)
    host.session_name(name)
    return name


def attach(name):
    name = resolve(name)
    records = host.inventory()
    record = next((record for record in records if record['name'] == name), None)
    if record is None or not record['alive']:
        raise ValueError('recorded session is not running; preserve its record and recover explicitly')
    directory = Path(os.environ.get('AGT_ZMX_STATE', Path.home() / '.local/state/agt-zmx'))
    environment = host.zmx_environment(directory)
    # If the daemon disappears between discovery and attach, run only false.
    # Never allow zmx's create-if-missing behavior to start a replacement shell.
    command = ['zmx', 'attach', host.session_name(name), 'false']
    os.execvpe(command[0], command, environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('list')
    commands.add_parser('attach').add_argument('name')
    args = parser.parse_args()
    try:
        if args.action == 'attach':
            attach(args.name)
        else:
            for record in host.inventory():
                # No resume identifiers, routes, or transcript contents in output.
                print(record['name'], record['agent'], 'running' if record['alive'] else 'ended', sep='\t')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'sessions: {error}\n')


if __name__ == '__main__':
    main()
