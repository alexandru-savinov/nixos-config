#!/usr/bin/env python3
"""Terminal-only discovery and attachment to recorded remote sessions.

`sessions open NAME` is the one way in to an aliased Claude conversation
(`sancta` on choir is a thin wrapper around `sessions open sancta`). The alias
names a backend record; that record's `resume` UUID and `cwd` name the
conversation. The decision, in order, under a per-conversation opener lock:

1. WRITERS. A writer is a process of THIS account whose argv[0] is Claude and
   which either (a) carries `--resume UUID`, `--resume=UUID`, `-r UUID` or
   `--session-id UUID`, (b) carries a bare `--resume`/`-r`/`--continue`/`-c`
   (no UUID; the picker) and runs in the conversation's cwd, or (c) is named
   for the UUID in Claude's own session metadata (CLAUDE_CONFIG_DIR/sessions/
   *.json, the same metadata `host.validate_resume` already reads). Only
   /proc/PID/{stat,cmdline,cwd} are read; never environ, never transcripts.
2. INSIDE OR OUTSIDE zmx is decided by ancestry: a writer is inside a backend
   when itself or an ancestor is the session child pid that `zmx list` reports
   for a backend in our ZMX_DIR, and "inside some other zmx" when an ancestor's
   comm is `zmx` but it is not one of ours.
3. Any writer OUTSIDE zmx (a raw `claude --resume` in a terminal): print its
   PID, TTY and start time, start nothing, exit 1. A writer inside a zmx
   session that is not a recorded live backend for this UUID: refuse, exit 1.
4. Exactly one live recorded backend for this UUID: attach to it (attach-only,
   `zmx attach NAME false`, as `sessions attach`). Several: refuse, exit 1.
5. A start by another opener began less than START_WINDOW seconds ago: wait up
   to START_POLL seconds for that backend to go live and attach; never start a
   second one.
6. Nothing anywhere: check the transcript exists, no metadata process is live
   and the cooperative writer lock is free, then start ONE new user-scope
   backend `NAME-open-YYYYmmdd-HHMMSS` whose only command is the existing
   recovery path `sessions resume --cwd CWD claude UUID`, and attach to it in
   the same exec. A failure is reported once; there is no retry loop.

Nothing here stops, kills or signals a process. The hard guarantee against two
writers stays in `host.resume_lock` + `host.validate_resume`, which the started
`sessions resume` takes again; this opener only avoids starting one needlessly.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import time

import host

UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
OPEN_WAIT = 10      # seconds to wait for another opener to finish deciding
START_WINDOW = 60   # a start marker younger than this means "starting"
START_POLL = 30     # seconds to wait for that start to go live
CLAUDE_NAMES = {"claude", ".claude-unwrapped"}


def resolve(name):
    path = Path('/etc/agt-zmx-aliases.json')
    if path.exists():
        aliases = json.loads(path.read_text()).get(pwd.getpwuid(os.getuid()).pw_name, {})
        name = aliases.get(name, name)
    host.session_name(name)
    return name


def state_path():
    return Path(os.environ.get('AGT_ZMX_STATE', Path.home() / '.local/state/agt-zmx'))


def exec_attach(name):
    environment = host.zmx_environment(state_path())
    # If the daemon disappears between discovery and attach, run only false.
    # Never allow zmx's create-if-missing behavior to start a replacement shell.
    command = ['zmx', 'attach', host.session_name(name), 'false']
    os.execvpe(command[0], command, environment)


def attach(name):
    requested, name = name, resolve(name)
    records = host.inventory()
    record = next((record for record in records if record['name'] == name), None)
    if record is None or not record['alive']:
        # Name the resolved backend so a stale /etc alias is visible, and point
        # at explicit recovery: this command never starts a replacement writer.
        target = name if requested == name else f'{requested} -> {name}'
        raise ValueError(
            f'{target}: recorded session is not running; preserve its record and '
            'recover explicitly (`sessions list`, `sessions resume`; see '
            'docs/agterm-zmx-recovery.md). If the backend was renamed, update '
            '/etc/agt-zmx-aliases.json declaratively')
    exec_attach(name)


# ── open: process table ─────────────────────────────────────────────────


def tty_name(number):
    if number == 0:
        return '?'
    major, minor = (number >> 8) & 0xfff, (number & 0xff) | ((number >> 12) & 0xfff00)
    if 136 <= major <= 143:
        return f'pts/{(major - 136) * 256 + minor}'
    if major == 4:
        return f'tty{minor}'
    return f'{major}:{minor}'


def processes(root=Path('/proc')):
    """pid -> {ppid, comm, tty, start}; argv and cwd only for this account."""
    root = Path(root)
    boot = 0
    try:
        for line in (root / 'stat').read_text().splitlines():
            if line.startswith('btime '):
                boot = int(line.split()[1])
    except OSError:
        pass
    ticks = os.sysconf('SC_CLK_TCK')
    uid = os.getuid()
    table = {}
    for entry in root.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / 'stat').read_text()
            owner = entry.stat().st_uid
        except OSError:
            continue  # exited while scanning
        comm = raw[raw.index('(') + 1:raw.rindex(')')]
        fields = raw[raw.rindex(')') + 2:].split()
        record = {'pid': int(entry.name), 'ppid': int(fields[1]), 'comm': comm,
                  'tty': tty_name(int(fields[4])), 'start': boot + int(fields[19]) / ticks,
                  'argv': [], 'cwd': None}
        if owner == uid:
            try:
                record['argv'] = [a for a in (entry / 'cmdline').read_bytes().decode(errors='replace').split('\0')]
                while record['argv'] and record['argv'][-1] == '':
                    record['argv'].pop()
                record['cwd'] = os.readlink(entry / 'cwd')
            except OSError:
                pass
        table[record['pid']] = record
    return table


def metadata_pids(identifier):
    """Pids Claude's own session metadata names for this conversation."""
    directory = Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home() / '.claude')) / 'sessions'
    try:
        paths = [path for path in directory.iterdir() if path.suffix == '.json']
    except FileNotFoundError:
        return set()
    except OSError:
        raise ValueError('cannot inspect conversation process metadata; refusing to open') from None
    pids = set()
    for path in paths:
        try:
            record = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(record, dict) and record.get('sessionId') == identifier:
            try:
                pids.add(int(record.get('pid')))
            except (TypeError, ValueError):
                continue
    return pids


def is_claude(process):
    argv = process['argv']
    return bool(argv) and (os.path.basename(argv[0]) in CLAUDE_NAMES or process['comm'] in CLAUDE_NAMES
                           or process['comm'].startswith('.claude-unwrap'))


def claims(process, identifier, cwd):
    argv, bare = process['argv'], False
    for index, argument in enumerate(argv[1:], 1):
        following = argv[index + 1] if index + 1 < len(argv) else None
        if argument in ('--resume', '-r', '--session-id'):
            if following == identifier:
                return True
            if argument != '--session-id' and (following is None or not UUID.fullmatch(following)):
                bare = True  # picker, or a search term: may land on this conversation
        elif argument in (f'--resume={identifier}', f'--session-id={identifier}'):
            return True
        elif argument in ('--continue', '-c'):
            bare = True
    return bare and process['cwd'] == cwd


def chain(table, pid):
    seen = []
    while pid in table and pid not in seen and len(seen) < 4096:
        seen.append(pid)
        pid = table[pid]['ppid']
    return seen


def backend_pids(environment):
    """session child pid -> backend name, from `zmx list` in our ZMX_DIR."""
    output = subprocess.check_output(['zmx', 'list'], env=environment, text=True, timeout=5)
    result = {}
    for line in output.splitlines():
        fields = dict(field.split('=', 1) for field in line.strip().split('\t') if '=' in field)
        name, pid = fields.get('name', ''), fields.get('pid', '')
        if name.startswith('agt-mvp-') and pid.isdigit():
            result[int(pid)] = name.removeprefix('agt-mvp-')
    return result


def describe(process):
    started = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(process['start']))
    return f"pid {process['pid']} tty {process['tty']} started {started}"


# ── open: decision ──────────────────────────────────────────────────────


def identity(name):
    """The alias's backend record names the conversation and its directory."""
    backend = resolve(name)
    path = state_path() / (host.session_name(backend) + '.json')
    try:
        record = json.loads(path.read_text())
    except FileNotFoundError:
        raise ValueError(f'{name} -> {backend}: no backend record; cannot tell which conversation to open') from None
    identifier, cwd = record.get('resume'), record.get('cwd')
    if record.get('agent') != 'claude' or not isinstance(identifier, str) or not UUID.fullmatch(identifier) \
            or not isinstance(cwd, str):
        raise ValueError(f'{name} -> {backend}: record is not a resumable Claude conversation')
    return identifier, cwd


def survey(identifier, cwd, environment, proc_root=Path('/proc')):
    """Return the live backend to attach to, or None if nothing runs. Raises on refusal."""
    table = processes(proc_root)
    named = metadata_pids(identifier)
    writers = [process for process in table.values()
               if is_claude(process) and (process['pid'] in named or claims(process, identifier, cwd))]
    live = {record['name'] for record in host.inventory()
            if record['alive'] and record['agent'] == 'claude' and record.get('resume') == identifier}
    owners = backend_pids(environment) if writers else {}
    outside, foreign, hosting = [], [], set()
    for writer in writers:
        ancestry = chain(table, writer['pid'])
        owner = next((owners[pid] for pid in ancestry if pid in owners), None)
        if owner is not None and owner in live:
            hosting.add(owner)
        elif owner is None and not any(table[pid]['comm'] == 'zmx' for pid in ancestry[1:]):
            outside.append(writer)
        else:
            foreign.append(writer)
    if outside:
        lines = '\n'.join('  ' + describe(writer) for writer in sorted(outside, key=lambda p: p['pid']))
        raise ValueError('this conversation already has a writer outside zmx; starting nothing:\n'
                         f'{lines}\nhint: exit that Claude yourself (it is the live one), then run this again')
    if foreign:
        pids = ', '.join(str(writer['pid']) for writer in foreign)
        raise ValueError(f'pid {pids} runs this conversation inside a zmx session that is not a recorded '
                         'live backend; starting nothing (`sessions list`)')
    candidates = hosting or live
    if len(candidates) > 1:
        raise ValueError('several live backends claim this conversation: ' + ', '.join(sorted(candidates))
                         + '; attach one explicitly with `sessions attach NAME`')
    return next(iter(candidates), None)


def opener_lock(directory, identifier):
    lock = (directory / f'open-{identifier}.lock').open('a')
    deadline = time.monotonic() + OPEN_WAIT
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except BlockingIOError:
            if time.monotonic() >= deadline:
                lock.close()
                raise ValueError('another opener is still deciding for this conversation; starting nothing') from None
            time.sleep(0.2)


def starting(directory, identifier, now):
    try:
        marker = json.loads((directory / f'open-{identifier}.starting').read_text())
        name, began = marker['name'], float(marker['time'])
        host.session_name(name)
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return name if 0 <= now - began < START_WINDOW else None


def start_backend(directory, requested, identifier, cwd, now):
    """Pre-check, then record + mark ONE new backend. Returns its exec argv/env."""
    host.validate_resume('claude', identifier)
    host.resume_lock(identifier, 'claude').close()  # probe the cooperative writer lock
    if not Path(cwd).is_dir():
        raise ValueError('working directory is not a directory')
    name = f"{requested}-open-{time.strftime('%Y%m%d-%H%M%S', time.localtime(now))}"
    qualified = host.session_name(name)
    path = directory / (qualified + '.json')
    if path.exists():
        raise ValueError(f'{name}: backend name already recorded; starting nothing, try again in a second')
    # Same record shape as `agt-zmx-host attach --resume --user-scope`, so the
    # Mac launcher and `sessions list/attach` treat it as an ordinary backend.
    host.write_json(path, {'cwd': cwd, 'agent': 'claude', 'resume': identifier, 'user_scope': True})
    host.write_json(directory / f'open-{identifier}.starting', {'name': name, 'time': now})
    environment = host.zmx_environment(directory)
    environment['PWD'] = cwd
    environment['XDG_RUNTIME_DIR'] = f'/run/user/{os.getuid()}'
    environment['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + environment['XDG_RUNTIME_DIR'] + '/bus'
    command = ['systemd-run', '--user', '--scope', '--collect', '--quiet', f'--unit={qualified}.scope', '--',
               'zmx', 'attach', qualified,
               sys.executable, str(Path(__file__).resolve()), 'resume', '--cwd', cwd, 'claude', identifier]
    return name, command, environment


def open_conversation(requested, proc_root=Path('/proc')):
    identifier, cwd = identity(requested)
    directory = host.state_dir()
    environment = host.zmx_environment(directory)
    lock = opener_lock(directory, identifier)
    try:
        target = survey(identifier, cwd, environment, proc_root)
        pending = None if target else starting(directory, identifier, time.time())
        launch = None
        if target is None and pending is None:
            launch = start_backend(directory, requested, identifier, cwd, time.time())
    finally:
        lock.close()
    if target is not None:
        return exec_attach(target)
    if pending is not None:
        deadline = time.monotonic() + START_POLL
        while time.monotonic() < deadline:
            if any(record['name'] == pending and record['alive'] for record in host.inventory()):
                return exec_attach(pending)
            time.sleep(0.5)
        raise ValueError(f'{pending}: a start began under a minute ago and is not live; starting nothing '
                         '(`sessions list`)')
    name, command, environment = launch
    print(f'sessions: starting {name} (sessions resume, once)', file=sys.stderr, flush=True)
    os.chdir(cwd)
    os.execvpe(command[0], command, environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('list')
    commands.add_parser('attach').add_argument('name')
    commands.add_parser('open', help='attach to the live writer of an aliased conversation, '
                                     'or start it once; refuses an outside-zmx writer').add_argument('name')
    recovery = commands.add_parser('resume', help='recover a stopped conversation; no interactive resume picker')
    recovery.add_argument('agent', choices=['claude', 'codex'])
    recovery.add_argument('identifier', help='explicit conversation UUID, never a name or picker')
    recovery.add_argument('--cwd', required=True)
    args = parser.parse_args()
    try:
        if args.action == 'attach':
            attach(args.name)
        elif args.action == 'open':
            open_conversation(args.name)
        elif args.action == 'resume':
            host.resume_terminal(args.agent, args.identifier, args.cwd)
        else:
            for record in host.inventory():
                # No resume identifiers, routes, or transcript contents in output.
                print(record['name'], record['agent'], 'running' if record['alive'] else 'ended', sep='\t')
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'sessions: {error}\n')


if __name__ == '__main__':
    main()
