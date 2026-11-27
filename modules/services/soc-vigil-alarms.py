"""soc-vigil-alarms — the two SOC alarms vigil cannot compute itself.

Root oneshots classify audit records and ban decisions. Vigil reads age
signals for hits, evaluator health, audit coverage gaps and log retention
without reading the audit trail or engine credentials.

Audit exit codes: 0 clean, 1 a hit is on hold, 2 evaluator error. Both
successful outcomes refresh audit-clean. The independent watchdog pages
when that heartbeat is more than 30 minutes old or auditd reports that it
has stopped recording.
Bans use exit 3 for a hit and a source error in the same run.

The classification functions (`audit_hits`, `home_bans`) are pure — text in,
verdicts out — so tests/test_soc_vigil_alarms.py can drive both arms of every
rule from fixture lines without root, without auditd, without CrowdSec.

THE AUDIT RULE (exact):
  An audit event fires iff ALL of:
    1. its SYSCALL record carries key `agenix-secrets` or `sudoers`
       (the two soc-in-a-box watches on config.age.secretsMountPoint and
       /etc/sudoers), AND
    2. its auid is SET — anything other than 4294967295 / -1. auid is the
       login uid: set once by pam_loginuid at an interactive login (ssh,
       console) and inherited by everything that login runs, sudo included.
       systemd services, timers, and nixos-rebuild's switch (which runs
       switch-to-configuration through `systemd-run`, nixos-rebuild-ng
       nix.py SWITCH_TO_CONFIGURATION_CMD_PREFIX) have it unset. auid 0 (a
       direct root login) counts as set. Attempts that FAIL (success=no) fire
       too: an attempt by a login on a secret is the signal, success or not.
       Tailscale SSH (choir's admin path): VERIFIED ONLY for an interactive
       terminal session, which the incubator hands to `login -f`, whose PAM
       stack has pam_loginuid (checked live on choir 2026-11-11: loginctl
       Service=login, loginuid 993 down the process tree). A session the
       incubator does NOT hand to login(1) gets no auid from this host's
       PAM stacks and is NOT covered by this rule: an open gap, for the
       owner to measure (the PR's post-deploy check).
    3. (There is no activation exemption: a login-attributed write to
       /etc/sudoers fires, whoever the writer claims to be. When the live
       file's sha256 equals that of the sudoers file in the etc tree of
       /run/current-system, the ALARM line says so as
       `sudoers_matches_generation`: journal context only, never a verdict.)
       A login's read of any agenix key fires, including the council user's
       own read of jev-openrouter-key; there is no per-key exemption.
  Everything else in the audit log is ignored here.

THE NAMED-ACCOUNT RULE (opt-in: --named-account NAME, repeatable; none = off):
  For each named account (uid resolved by pwd.getpwnam at the start of every
  run; a name that does not resolve is an evaluator error), a hit fires on
    - kind "admin-root-exec": any event whose SYSCALL carries key `root-exec`
      (euid 0 execve from a login, soc-in-a-box) and whose auid is the
      account's uid. Logs exe, comm and the decoded proctitle.
    - kind "admin-session": a USER_LOGIN or USER_START record (what sshd and
      PAM write) for the account with res=success: acct="NAME", or id=<uid>
      (sshd's USER_LOGIN success form carries id= rather than acct=), or, for
      USER_LOGIN only, auid=<uid>. Logs addr, hostname, terminal, exe. A
      USER_START whose acct is another user (sudo opening root's session) is
      not a session of the account; the sudo is the root-exec above.
      One ssh login normally yields both record types, so two hits.
  A matching record with res=failed is NOT a hit: it logs a NOTICE line only
  (wrong passwords and scanners make failures noisy; the sshd/fail2ban side
  already counts them). A matching record with no res is malformed: error.
  No extra ausearch is needed: run_ausearch has no -k and reads every record
  type since the checkpoint, so these records are already in the window and
  share its checkpoint, staging and commit-after-log properties.

EVALUATOR ERRORS (exit 2) on the audit side, besides unparseable lines:
  auditctl -s/-l or auditd's state report unhealthy (see check_trail);
  ausearch exit 1 with stdout,
  exit 0 with stderr, or any other failure (the window is read again, not
  consumed); a missing checkpoint once audit.installed exists (the
  marker is written when a checkpoint is first committed; a missing one
  before that is the first run); a SYSCALL record lacking arch, syscall,
  success, exe or key; a PATH record in an event with no SYSCALL record.
  Checkpoint statuses 10/11/12 trigger a retained-log replay and a separate
  incident until an operator removes audit.checkpoint-mismatch.

THE BAN RULE (exact):
  Fires iff any address in `neverBan` (soc-in-a-box; the same list fail2ban
  receives as ignoreIP) is
    - the value of any current CrowdSec decision (scope Ip, or scope Range
      overlapping a neverBan range), any type, any origin; CrowdSec's
      s02 whitelist drops these addresses before a scenario can see them, so
      a decision here is either a whitelist failure or a manual
      `cscli decisions add` — both are the alarm; OR
    - in fail2ban's sshd "Banned IP list" — ignoreIP should have made this
      impossible, so it is the same whitelist failure on the actual banner.
  Decisions on public addresses are the normal detect-only output and are
  ignored.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import tempfile
import time

WATCHED_KEYS = frozenset({"agenix-secrets", "sudoers"})
UNSET_AUID = {"4294967295", "-1", "unset"}
AUDIT_RETENTION_SECONDS = 48 * 60 * 60

# Optional `node=<name> ` prefix: auditd writes it when name_format != none.
_HEADER = re.compile(r"^(?:node=\S+ )?type=(\S+) msg=audit\(([0-9.]+):([0-9]+)\):\s?(.*)$")
# The only non-record lines ausearch prints: its event separator and the
# legacy empty-result note.
_SEPARATORS = frozenset({"", "----", "<no matches>"})
_FIELD = re.compile(r'([A-Za-z0-9_-]+)=("[^"]*"|\S+)')
# What every SYSCALL record must carry for the rules to read it. auid is not
# here: a watched SYSCALL without auid is an existing hit (audit_scan).
_SYSCALL_REQUIRED = ("arch", "syscall", "success", "exe", "key")
_INNER = re.compile(r"msg='(.*)'")
_SESSION_TYPES = frozenset({"USER_LOGIN", "USER_START"})
_HEX = re.compile(r"^(?:[0-9A-Fa-f]{2})+$")


# ── audit: raw record parsing ──────────────────────────────────────────────

def _fields(body: str) -> dict:
    # ENRICHED log_format appends interpreted fields after a GS (0x1d)
    # separator. Only the kernel's raw half is trusted here.
    raw = body.split("\x1d", 1)[0]
    out = {m.group(1): m.group(2) for m in _FIELD.finditer(raw)}
    # User-space records (USER_LOGIN, USER_START, ...) wrap their payload in
    # msg='op=... res=success'. Lift those fields; top-level ones win.
    inner = _INNER.search(raw)
    if inner:
        for m in _FIELD.finditer(inner.group(1)):
            out.setdefault(m.group(1), m.group(2))
        out["msg"] = inner.group(1)
    return out


def _unhex(value: str) -> str | None:
    if value.startswith('"') and value.endswith('"') and len(value) >= 2:
        return value[1:-1]
    if value == "(null)":
        return None
    if _HEX.match(value):
        return bytes.fromhex(value).decode("utf-8", "replace")
    return value


def scan_events(raw_text: str) -> tuple[list[dict], list[str]]:
    """Group raw audit lines into events by (timestamp, serial), in order.
    Returns (events, unparseable-line notes) so a single bad line cannot hide
    the good events around it. A line that is neither a record nor an ausearch
    separator is a note, never silently dropped: if the trail's format ever
    stops matching, parsing nothing would read as a clean window forever."""
    events: dict[tuple[str, str], dict] = {}
    bad: list[str] = []
    # split("\n"), NOT splitlines(): str.splitlines() also breaks on GS
    # (0x1d), which is exactly the byte that separates the ENRICHED half of
    # a record, so every enriched record would become two "lines".
    for n, line in enumerate(raw_text.replace("\r\n", "\n").split("\n"), 1):
        m = _HEADER.match(line.strip())
        if not m:
            if line.strip() in _SEPARATORS:
                continue
            bad.append(f"unparseable audit line {n} (format drift?): {line[:80]!r}")
            continue
        rtype, ts, serial, body = m.groups()
        ev = events.setdefault((ts, serial), {"ts": ts, "serial": serial, "records": []})
        ev["records"].append((rtype, _fields(body)))
    return list(events.values()), bad


def _keys(syscall: dict) -> set[str]:
    value = syscall.get("key")
    if value is None:
        return set()
    decoded = _unhex(value)
    if decoded is None:
        return set()
    # Several keys on one rule are joined with SOH (0x01) and hex-encoded.
    return {k for k in decoded.split("\x01") if k}


def _paths(event: dict) -> list[str]:
    out = []
    for rtype, f in event["records"]:
        if rtype == "PATH" and "name" in f:
            name = _unhex(f["name"])
            if name:
                out.append(name)
    return out




def _admin_scan(events: list[dict], admins: dict[str, str]) -> tuple[list[dict], list[str], list[str]]:
    """PURE. THE NAMED-ACCOUNT RULE over parsed events. admins: name -> uid
    (as a string). Returns (hits, bad lines, notices)."""
    by_uid = {uid: name for name, uid in admins.items()}
    hits: list[dict] = []
    bad: list[str] = []
    notices: list[str] = []
    for ev in events:
        where = f"event {ev['ts']}:{ev['serial']}"
        base = {"ts": ev["ts"], "serial": ev["serial"]}
        syscall = next((f for t, f in ev["records"] if t == "SYSCALL"), None)
        if syscall is not None and "root-exec" in _keys(syscall) and syscall.get("auid") in by_uid:
            title = next((f.get("proctitle") for t, f in ev["records"] if t == "PROCTITLE"), None)
            decoded = _unhex(title) if title else None
            hits.append({**base, "kind": "admin-root-exec", "account": by_uid[syscall["auid"]],
                         "auid": syscall["auid"], "keys": ["root-exec"],
                         "exe": _unhex(syscall.get("exe", "")) or "?",
                         "comm": _unhex(syscall.get("comm", "")) or "?",
                         "proctitle": (decoded or "?").replace("\x00", " ")})
        for rtype, f in ev["records"]:
            if rtype not in _SESSION_TYPES:
                continue
            acct = _unhex(f["acct"]) if "acct" in f else None
            who = None
            if acct in admins:
                who = acct
            elif f.get("id") in by_uid:
                who = by_uid[f["id"]]
            elif rtype == "USER_LOGIN" and f.get("auid") in by_uid:
                who = by_uid[f["auid"]]
            if who is None:
                continue
            res = f.get("res", "").strip("'\"")
            if res in ("success", "1"):
                hits.append({**base, "kind": "admin-session", "account": who, "record": rtype,
                             "auid": f.get("auid"),
                             "addr": f.get("addr"), "hostname": f.get("hostname"),
                             "terminal": f.get("terminal"),
                             "exe": _unhex(f.get("exe", "")) or "?", "keys": []})
            elif res in ("failed", "0"):
                notices.append(f"{where}: failed {rtype} for {who} addr={f.get('addr')} "
                               f"terminal={f.get('terminal')}")
            else:
                bad.append(f"{where}: {rtype} for {who} without a usable res")
    return hits, bad, notices


def audit_hits(raw_text: str, admins: dict[str, str] | None = None) -> list[dict]:
    """PURE. Apply THE AUDIT RULE (module docstring) to `ausearch --raw` text.
    Raises ValueError on any unparseable or malformed record (see scan_events, audit_scan)."""
    hits, bad = audit_scan(raw_text, admins)
    if bad:
        raise ValueError(bad[0])
    return hits


def audit_scan(raw_text: str, admins: dict[str, str] | None = None) -> tuple[list[dict], list[str]]:
    """PURE. THE AUDIT RULE over every parseable event, plus the bad lines.
    `admins` (name -> uid) adds the named-account rule; None or empty = off."""
    events, bad = scan_events(raw_text)
    hits = []
    for ev in events:
        where = f"event {ev['ts']}:{ev['serial']}"
        syscall = next((f for t, f in ev["records"] if t == "SYSCALL"), None)
        if syscall is None:
            if any(t == "PATH" for t, _ in ev["records"]):
                bad.append(f"{where}: PATH record without a SYSCALL record")
            continue
        missing = [k for k in _SYSCALL_REQUIRED if k not in syscall]
        if missing:
            bad.append(f"{where}: SYSCALL record lacks {', '.join(missing)}")
        # A key cut mid-string (no closing quote) names no key: it must not
        # read as "no watched key".
        rawkey = syscall.get("key", "")
        if rawkey.startswith('"') and (len(rawkey) < 2 or not rawkey.endswith('"')):
            bad.append(f"{where}: SYSCALL key is not terminated")
        keys = _keys(syscall) & WATCHED_KEYS
        if not keys:
            continue
        # A PATH whose name is (null) on a watched key says nothing about
        # which file was touched: the rule cannot be applied, so it is an error.
        path_records = [f for t, f in ev["records"] if t == "PATH"]
        if any("name" in f and _unhex(f["name"]) in (None, "(null)") for f in path_records):
            bad.append(f"{where}: PATH record with name (null) on a watched key")
        # Completeness: every PATH record names its file and item, and the
        # event carries as many PATH records as the SYSCALL announced.
        if any("name" not in f or "item" not in f for f in path_records):
            bad.append(f"{where}: PATH record without name or item on a watched key")
        try:
            announced = int(syscall.get("items", ""))
        except ValueError:
            bad.append(f"{where}: SYSCALL items missing or not a number on a watched key")
        else:
            if len({f["item"] for f in path_records if "item" in f}) < announced:
                bad.append(f"{where}: fewer PATH records than SYSCALL items ({announced}) on a watched key")
        auid = syscall.get("auid")
        # A watched SYSCALL record without auid is malformed beyond anything
        # this rule was written for: fire rather than guess it was routine.
        if auid is not None and auid in UNSET_AUID:
            continue
        hits.append({
            "ts": ev["ts"],
            "serial": ev["serial"],
            "keys": sorted(keys),
            "auid": auid,
            "success": syscall.get("success"),
            "exe": _unhex(syscall.get("exe", "")) or "?",
            "paths": _paths(ev),
        })
    if admins:
        a_hits, a_bad, notices = _admin_scan(events, admins)
        hits += a_hits
        bad += a_bad
        for n in notices:
            _log("NOTICE audit " + n)
    return hits, bad


# ── bans ───────────────────────────────────────────────────────────────────

def _networks(cidrs: list[str]) -> list:
    return [ipaddress.ip_network(c, strict=False) for c in cidrs]


def _in_home(value: str, nets: list) -> bool:
    net = ipaddress.ip_network(value.strip(), strict=False)
    candidates = [net]
    if net.version == 6 and net.prefixlen == 128 and net.network_address.ipv4_mapped:
        candidates.append(ipaddress.ip_network(net.network_address.ipv4_mapped))
    return any(c.version == h.version and c.overlaps(h) for c in candidates for h in nets)


def crowdsec_scan(decisions_json: str, nets: list) -> tuple[list[dict], list[str]]:
    """PURE. (hits, errors) for `cscli decisions list -o json`. Every readable
    decision is classified even when another entry is not, so one malformed
    entry cannot hide a home-address decision next to it."""
    hits: list[dict] = []
    errors: list[str] = []
    # Only the documented "no decisions" answers are clean: JSON null or [].
    # Empty output, or an entry without the fields read below, is unreadable.
    if not decisions_json.strip():
        return hits, ["cscli output is empty"]
    try:
        alerts = json.loads(decisions_json)
    except ValueError as e:
        return hits, [f"cscli output is not JSON: {e}"]
    if alerts is None:
        alerts = []
    if not isinstance(alerts, list):
        return hits, ["cscli output is not a list"]
    for alert in alerts:
        if not isinstance(alert, dict) or not isinstance(alert.get("decisions"), list):
            errors.append(f"cscli alert without a decisions list: {str(alert)[:80]}")
            continue
        for d in alert["decisions"]:
            if not isinstance(d, dict) or "scope" not in d or "value" not in d:
                errors.append(f"cscli decision without scope/value: {str(d)[:80]}")
                continue
            if not all(isinstance(d[k], str) and d[k].strip() for k in ("scope", "value")):
                errors.append(f"cscli decision with a null, non-string or empty scope/value: {str(d)[:80]}")
                continue
            if d["scope"].lower() not in ("ip", "range"):
                continue
            try:
                home = _in_home(d["value"], nets)
            except ValueError as e:
                errors.append(f"cscli decision value is not an address: {e}")
                continue
            if home:
                hits.append({"engine": "crowdsec", "value": d["value"], "type": d.get("type")})
    return hits, errors


def fail2ban_scan(fail2ban_status: str, nets: list) -> tuple[list[dict], list[str]]:
    """PURE. (hits, errors) for `fail2ban-client status sshd`."""
    banned_line = None
    for line in fail2ban_status.splitlines():
        if "Banned IP list:" in line:
            banned_line = line.split("Banned IP list:", 1)[1]
    if banned_line is None:
        return [], ["fail2ban status has no 'Banned IP list' line"]
    hits, errors = [], []
    for ip in banned_line.split():
        try:
            if _in_home(ip, nets):
                hits.append({"engine": "fail2ban", "value": ip, "type": "ban"})
        except ValueError as e:
            errors.append(f"fail2ban banned address is not an address: {e}")
    return hits, errors


def home_bans(decisions_json: str, fail2ban_status: str, cidrs: list[str]) -> list[dict]:
    """PURE. Apply THE BAN RULE (module docstring).

    decisions_json: stdout of `cscli decisions list -o json` (`null` or `[]` = none).
    fail2ban_status: stdout of `fail2ban-client status sshd`.
    Raises ValueError on input it cannot read: unreadable is not clean.
    """
    nets = _networks(cidrs)
    if not nets:
        raise ValueError("empty neverBan list")
    hits, errors = crowdsec_scan(decisions_json, nets)
    more_hits, more_errors = fail2ban_scan(fail2ban_status, nets)
    if errors or more_errors:
        raise ValueError((errors + more_errors)[0])
    return hits + more_hits


# ── runners (impure: exec, state files) ─────────────────────────────────────

def _log(msg: str) -> None:
    print(msg, flush=True)


def run_ausearch(ausearch, checkpoint, output, *, recent=False, input_dir=None):
    # Passing a fresh checkpoint with no start filter tells ausearch to start
    # at its oldest retained file and save the last complete event it reads.
    source = ["--input", input_dir] if input_dir else ["--input-logs"]
    argv = [ausearch, *source, "--raw", "--checkpoint", checkpoint]
    if recent:
        argv += ["--start", "recent"]
    p = subprocess.run(argv, stdout=output, stderr=subprocess.PIPE,
                       encoding="utf-8", errors="replace", stdin=subprocess.DEVNULL)
    has_output = output.tell() > 0
    output.seek(0)
    err = p.stderr.strip()
    if input_dir:
        note = f"NOTE - using logs in {input_dir}/audit.log"
        err = "\n".join(line for line in err.splitlines() if line != note)
    if p.returncode == 0 and not err:
        return p.returncode, None
    if p.returncode == 1 and not has_output and err in ("", "<no matches>"):
        return p.returncode, None
    if p.returncode == 1 and has_output:
        return p.returncode, "ausearch exited 1 with output on stdout"
    return p.returncode, f"ausearch exited {p.returncode}" + (f": {err[:300]}" if err else "")


def audit_batches(output):
    # A retained-log replay can be hundreds of MiB. Ausearch emits each
    # complete event contiguously; batch only between events.
    lines = []
    previous = None
    for line in output:
        record = _HEADER.match(line.strip())
        if record:
            event = record.group(2, 3)
            if len(lines) >= 4096 and event != previous:
                yield "".join(lines)
                lines.clear()
            previous = event
        lines.append(line)
    if lines:
        yield "".join(lines)


def _fsync_dir(path: str) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_durably(path: str, text: str) -> None:
    """Write-then-rename, fsynced: a crash leaves the old file or the new
    one, never an empty one (an empty last-hit would read as "no hold")."""
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    _fsync_dir(os.path.dirname(path))


def audit_log_paths(directory):
    files = set(os.listdir(directory))
    chain = ["audit.log"]
    while f"audit.log.{len(chain)}" in files:
        chain.append(f"audit.log.{len(chain)}")
    return [os.path.abspath(os.path.join(directory, name)) for name in reversed(chain)]


def oldest_audit_record(directory):
    # Match ausearch's numbered rotation chain, starting at the oldest
    # contiguous member. A rotation may rename a file between list and open.
    for _ in range(2):
        try:
            for path in audit_log_paths(directory):
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        record = _HEADER.match(line.strip())
                        if record:
                            return record.group(2)
        except FileNotFoundError:
            continue
    raise RuntimeError(f"no retained audit record readable in {directory}")


def audit_file_id(path):
    info = os.stat(path)
    return [info.st_dev, info.st_ino]


def audit_checkpoint_text(file_id, boundary):
    dev, inode = file_id
    return f"dev=0x{dev:X}\ninode={inode}\n{boundary}\n"


def replay_checkpoint_anchor(paths, boundary):
    match = re.fullmatch(r"output=(\S+) ([0-9]+\.[0-9]+:[0-9]+) 0x[0-9a-fA-F]+", boundary)
    if not match:
        raise RuntimeError("invalid ausearch replay checkpoint event")
    node, event = match.groups()
    if event == "0.000:0":  # ausearch has yet to emit a complete event
        return 0
    # Search the raw logs, since ausearch writes the final input file's inode
    # even when the last complete event started in an earlier file. Keep that
    # earlier file available so the next chunk can assemble the same event.
    needle = f" msg=audit({event}):".encode()
    prefix = (b"" if node == "-" else f"node={node} ".encode()) + b"type="
    for index, path in enumerate(paths):
        with open(path, "rb") as fh:
            for line in fh:
                offset = line.find(needle)
                if offset >= 0 and line.startswith(prefix) and b" " not in line[len(prefix):offset]:
                    return index
    raise RuntimeError("ausearch replay checkpoint event missing from its input logs")


def replay_audit(a, replay_state, staged, classify):
    paths = audit_log_paths(a.audit_log_dir)
    file_ids = [audit_file_id(path) for path in paths]
    cursor = json.loads(_read_text(replay_state))
    start = end = 0
    boundary = None
    if cursor:
        if cursor["through"] in file_ids and cursor["anchor"] in file_ids:
            # Rotation renames files. Resume by device and inode, and recheck
            # the active file if it was the last committed chunk.
            start = file_ids.index(cursor["anchor"])
            end = min(file_ids.index(cursor["through"]) + 1, len(paths) - 1)
            boundary = cursor["boundary"]
        else:
            _log("WARN audit replay cursor rotated out; restarting from the oldest retained log")

    for end in range(end, len(paths)):
        if boundary:
            _write_durably(staged, audit_checkpoint_text(file_ids[start], boundary))
        elif os.path.exists(staged):
            os.unlink(staged)
        # Each chunk adds one file. Keep the necessary overlap so ausearch
        # can assemble events whose records straddle a rotation boundary.
        chunk = paths[start:end + 1]
        with tempfile.TemporaryDirectory() as input_dir, \
                tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace") as output:
            for index, path in enumerate(reversed(chunk)):
                name = f"audit.log.{index}" if index else "audit.log"
                os.symlink(path, os.path.join(input_dir, name))
            _, problem = run_ausearch(a.ausearch, staged, output, input_dir=input_dir)
            if problem:
                raise RuntimeError(problem)
            result = _read_text(staged)
            if not result:
                raise RuntimeError("ausearch replay did not write a checkpoint")
            boundary = result.splitlines()[-1]
            next_start = start + replay_checkpoint_anchor(chunk, boundary)
            if [audit_file_id(path) for path in chunk] != file_ids[start:end + 1]:
                raise RuntimeError("audit logs rotated during replay chunk")
            classify(output)
        start = next_start
        _write_durably(replay_state, json.dumps({
            "through": file_ids[end], "anchor": file_ids[start], "boundary": boundary,
        }))

    if boundary == "output=- 0.000:0 0x0":
        raise RuntimeError("ausearch replay found no complete event to checkpoint")
    _write_durably(staged, audit_checkpoint_text(file_ids[start], boundary))


def protect_gap_evidence(chattr, path):
    result = subprocess.run([chattr, "+a", path], capture_output=True, text=True,
                            stdin=subprocess.DEVNULL, env={**os.environ, "LC_ALL": "C"})
    if result.returncode:
        detail = result.stderr.strip()
        error = detail.removeprefix(f"{chattr}: ")
        if error.startswith(("Operation not supported ", "Inappropriate ioctl for device ")):
            _log(f"WARN audit coverage gap: filesystem does not support chattr +a: {detail}")
        else:
            raise RuntimeError(f"chattr +a exited {result.returncode}: {detail[:300]}")


def record_coverage_gap(state, checkpoint, log_dir, status, chattr):
    marker = os.path.join(state, "audit.checkpoint-mismatch")
    if not os.path.lexists(marker):
        _write_durably(marker, f"{time.time():.0f}\n")

    stamp = os.path.join(state, "audit.coverage-gap")
    pending = os.path.join(state, "audit.gap-pending")
    identity = [os.stat(checkpoint).st_ino, _sha256(checkpoint)]
    saved = json.loads(_read_text(pending) or "null")
    fd = os.open(stamp, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        # Also protect an existing file if creation was interrupted or it
        # predates the flag. Keep the original inode and contents.
        protect_gap_evidence(chattr, stamp)
        end = os.fstat(fd).st_size
        if saved and saved["checkpoint"] == identity:
            offset, entry = saved["offset"], saved["entry"]
        else:
            # Status 10 can mean that the original timestamp is unreadable.
            with open(checkpoint, encoding="utf-8", errors="replace") as fh:
                match = re.search(r"^output=\S+ ([0-9]+\.[0-9]+):", fh.read(), re.MULTILINE)
            start = match.group(1) if match else "unknown"
            oldest = oldest_audit_record(log_dir)
            prefix = "\n" if end and os.pread(fd, 1, end - 1) != b"\n" else ""
            offset = end
            entry = f"{prefix}from={start} to={oldest} cause={status}\n"
            _write_durably(pending, json.dumps({"checkpoint": identity, "offset": offset, "entry": entry}))
        # Persist intent before appending. Retry the same record, even if the
        # oldest retained log moved or a crash interrupted the write.
        data = entry.encode()
        written = end - offset
        if not (0 <= written <= len(data)) or os.pread(fd, written, offset) != data[:written]:
            raise RuntimeError("coverage gap stamp changed during an unfinished append")
        if written < len(data) and os.write(fd, data[written:]) != len(data) - written:
            raise RuntimeError("short coverage gap stamp append")
        os.fsync(fd)
        _fsync_dir(state)
    finally:
        os.close(fd)
    _log("AUDIT COVERAGE GAP " + entry.strip())


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_text(path: str) -> str | None:
    try:
        with open(path) as fh:
            return fh.read().strip()
    except FileNotFoundError:
        return None


def sudoers_context(a) -> bool | None:
    """Journal context for a sudoers hit: does the live /etc/sudoers equal the
    sudoers file in the etc tree of the current system? None when that cannot
    be read. Never raises and never decides anything."""
    try:
        return _sha256(a.etc_sudoers) == _sha256(os.path.join(a.current_system, "etc", "sudoers"))
    except OSError:
        return None


def _auditctl(a, *args: str) -> str:
    p = subprocess.run([a.auditctl, *args], capture_output=True, text=True,
                       stdin=subprocess.DEVNULL, timeout=10)
    if p.returncode != 0:
        raise RuntimeError(f"auditctl {' '.join(args)} exited {p.returncode}: {p.stderr.strip()[:300]}")
    return p.stdout


def check_auditd_recording(a):
    # auditctl -s reports kernel state. Auditd can stay registered and
    # consume events while suspending writes, even after disk space returns.
    try:
        previous = os.stat(a.auditd_state_file).st_mtime_ns
    except FileNotFoundError:
        previous = None
    _auditctl(a, "--signal", "state")
    deadline = time.monotonic() + 5
    marker = os.path.join(a.state_dir, "audit.recording-unhealthy")
    while time.monotonic() < deadline:
        try:
            with open(a.auditd_state_file, encoding="utf-8") as report:
                if os.fstat(report.fileno()).st_mtime_ns != previous:
                    lines = set(report.read().splitlines())
                    for reason in ("logging suspended = yes", "writing to logs = no"):
                        if reason in lines:
                            mark_ran(marker)
                            raise RuntimeError(f"auditd not recording: {reason}")
                    if {"writing to logs = yes", "logging suspended = no"} <= lines:
                        try:
                            os.unlink(marker)
                        except FileNotFoundError:
                            pass
                        return
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    raise RuntimeError(f"auditd did not write a fresh recording state to {a.auditd_state_file}")


def audit_status(text: str) -> tuple[int, int, int]:
    """PURE. (enabled, lost, pid) from `auditctl -s`. Raises ValueError if any
    is missing or not a number."""
    found = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in ("enabled", "lost", "pid"):
            found[parts[0]] = int(parts[1])
    if not {"enabled", "lost", "pid"} <= found.keys():
        raise ValueError("auditctl -s output has no enabled/lost/pid counters")
    return found["enabled"], found["lost"], found["pid"]


def _normalize_rule(line: str) -> str:
    """One `auditctl -l` line with single spaces and permission letters
    sorted, so that only a real difference in the rule changes it."""
    t = line.split()

    def unslash(path: str) -> str:
        # auditctl lists a watch that resolved to a directory with a trailing
        # "/" (`-w /run/agenix.d/ …`) whether or not the rule was written with
        # one; one trailing slash is not a different rule.
        return path[:-1] if len(path) > 1 and path.endswith("/") else path

    for i, tok in enumerate(t):
        if tok == "-p" and i + 1 < len(t):
            t[i + 1] = "".join(sorted(t[i + 1]))
        elif tok == "-w" and i + 1 < len(t):
            t[i + 1] = unslash(t[i + 1])
        elif tok == "-F" and i + 1 < len(t) and t[i + 1].startswith("perm="):
            t[i + 1] = "perm=" + "".join(sorted(t[i + 1][5:]))
        elif tok == "-F" and i + 1 < len(t) and t[i + 1].startswith(("path=", "dir=")):
            name, _, value = t[i + 1].partition("=")
            t[i + 1] = f"{name}={unslash(value)}"
    return " ".join(t)


def loaded_rules(text: str) -> set[str]:
    """PURE. Every rule line of `auditctl -l`, normalized."""
    return {_normalize_rule(line) for line in text.splitlines() if line.strip()}


def expected_rule_lines(spec: str) -> set[str]:
    """PURE. The whole rule line(s) auditctl prints for an expected watch:
    `-w PATH -p PERM -k KEY`, or the equivalent filter form. Anything else on
    the line (another field such as a uid filter, a syscall, an arch) is a
    different rule."""
    path, perm, key = parse_expected_watch(spec)
    perm = "".join(sorted(perm))
    return {f"-w {path} -p {perm} -k {key}",
            f"-a always,exit -F path={path} -F perm={perm} -F key={key}",
            f"-a always,exit -F dir={path} -F perm={perm} -F key={key}"}


def parse_expected_watch(spec: str) -> tuple[str, frozenset, str]:
    path, perm, key = spec.rsplit(":", 2)
    if not (path.startswith("/") and perm and key):
        raise ValueError(f"bad --expect-watch {spec!r} (want PATH:PERM:KEY)")
    return path, frozenset(perm), key


def check_disk(a) -> None:
    """The audit log's filesystem must have room: auditd suspends writing when
    space runs out (disk_full_action / admin_space_left_action = suspend) and
    stays "active". Below --disk-warn-bytes free: a WARN line, still clean.
    Below --disk-fail-bytes free, or below --inode-fail-percent free inodes:
    an evaluator error. An unreadable filesystem is an error too."""
    try:
        st = os.statvfs(a.audit_log_dir)
    except OSError as e:
        raise RuntimeError(f"cannot stat the audit log filesystem {a.audit_log_dir}: {e}") from e
    free = st.f_bavail * st.f_frsize
    gib = 1024 ** 3
    if free < a.disk_fail_bytes:
        raise RuntimeError(f"audit log filesystem nearly full: {free / gib:.1f} GiB free "
                           f"(below {a.disk_fail_bytes / gib:.1f} GiB)")
    if st.f_files > 0:  # filesystems with dynamic inodes report 0: nothing to check
        pct = 100.0 * st.f_favail / st.f_files
        if pct < a.inode_fail_percent:
            raise RuntimeError(f"audit log filesystem out of inodes: {pct:.1f}% free "
                               f"(below {a.inode_fail_percent}%)")
    if free < a.disk_warn_bytes:
        _log(f"WARN audit: {free / gib:.1f} GiB free on the audit log filesystem "
             f"(warn below {a.disk_warn_bytes / gib:.1f} GiB)")


def check_trail(a, last_lost_path: str, start_hold) -> str | None:
    """Trail health, checked on every evaluation before a quiet window is
    accepted. Returns a problem to report after reading the window if the
    kernel lost counter moved. Raises when the trail cannot record."""
    enabled, lost, pid = audit_status(_auditctl(a, "-s"))
    if enabled not in (1, 2):
        raise RuntimeError(f"audit trail not recording: auditctl -s enabled={enabled}")
    if pid == 0:
        raise RuntimeError("audit trail not recording: no auditd registered with the kernel (pid 0)")
    boot = _read_text(a.boot_id_file)
    if not boot:
        raise RuntimeError(f"boot id unreadable ({a.boot_id_file})")
    stored = _read_text(last_lost_path)
    previous = None  # (boot id, lost) recorded by the last evaluation of the SAME boot
    if stored and len(stored.split()) == 2:
        sb, sl = stored.split()
        if sb == boot and sl.isdigit():
            previous = int(sl)
    problem = None
    if previous is not None and lost != previous:
        # The kernel counter only grows within a boot: a rise is dropped
        # events, a fall is state this check cannot trust. Persist the loss
        # incident before advancing the baseline so a retry can still page.
        if lost > previous:
            mark_ran(os.path.join(a.state_dir, "audit.kernel-loss"))
        problem = (f"audit trail lost {lost - previous} event(s) since the last evaluation"
                   if lost > previous else
                   f"audit lost counter fell from {previous} to {lost} within one boot")
        # Context only, never an exemption: a deploy in progress is exactly
        # when a loss must stay visible. The flag's mtime is logged so a stale
        # or misplaced flag is itself evidence.
        flag = getattr(a, "deploy_flag", None)
        if flag and os.path.lexists(flag):
            try:
                since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.lstat(flag).st_mtime))
            except OSError:
                since = "unknown"
            problem += f" (deploy in progress: {flag} present since {since})"
        start_hold()
    if previous != lost or stored is None or not stored.startswith(boot):
        _write_durably(last_lost_path, f"{boot} {lost}\n")
    if not a.expect_watch:
        raise RuntimeError("no --expect-watch given: cannot prove the watch rules are loaded")
    loaded = loaded_rules(_auditctl(a, "-l"))
    missing = [spec for spec in a.expect_watch if not (expected_rule_lines(spec) & loaded)]
    if missing:
        raise RuntimeError("audit watch rule(s) not loaded exactly as expected: " + ", ".join(missing))
    check_auditd_recording(a)
    check_disk(a)
    return problem


def check_stamp(a, ran_marker: str, stamps: list[str] | None = None) -> None:
    """Require an outcome stamp once the evaluator has run. ExecStopPost
    recreates a missing stamp with an invalid mtime so the next evaluation
    can proceed. The evaluator itself leaves these outcomes untouched."""
    stamps = stamps if stamps is not None else [a.stamp]
    if not all(stamps):
        raise RuntimeError("no stamp path (set --stamp / SANCTA_DOCTRINE_STAMP, and --health-stamp / SOC_HEALTH_STAMP for bans)")
    for stamp in stamps:
        if os.path.exists(ran_marker) and not os.path.lexists(stamp):
            raise RuntimeError(f"outcome stamp {stamp} is missing after an earlier run")


def mark_ran(ran_marker: str) -> None:
    if not os.path.exists(ran_marker):
        _write_durably(ran_marker, f"{time.time():.0f}\n")


def cmd_audit(a) -> int:
    if not a.state_dir or not os.path.isdir(a.state_dir):
        raise RuntimeError("no state directory (set --state-dir or STATE_DIRECTORY)")
    with open(os.path.join(a.state_dir, "audit.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return evaluate_audit(a)


def evaluate_audit(a) -> int:
    # Resolved first, every run: a name that does not resolve is an evaluator
    # error (KeyError -> exit 2), never a silently inert rule.
    admins = {}
    for name in dict.fromkeys(a.named_account):
        try:
            admins[name] = str(pwd.getpwnam(name).pw_uid)
        except KeyError:
            raise RuntimeError(f"named account {name!r} does not resolve (getpwnam)") from None
    checkpoint = os.path.join(a.state_dir, "audit.checkpoint")
    replay_state = os.path.join(a.state_dir, "audit.replay")
    last_hit = os.path.join(a.state_dir, "audit.last-hit")
    # A quiet window is only evidence when the trail can record. auditd down,
    # or audit-rules-nixos failed (its ExecStopPost deletes EVERY rule), also
    # yields a silent exit 1 from ausearch; without this gate that blind state
    # would read clean forever. check_trail also verifies the kernel rules
    # and auditd's current recording state.
    if not a.require_active:
        raise RuntimeError("no --require-active unit given: cannot prove the trail is live")
    # One call PER unit: with several units `systemctl is-active` exits 0 if
    # ANY of them is active (systemctl(1)), which would pass with auditd up
    # and the rules unit failed — the exact blind state this gate exists for.
    for unit in a.require_active:
        live = subprocess.run([a.systemctl, "is-active", "--quiet", "--", unit],
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if live.returncode != 0:
            raise RuntimeError(f"audit trail not live: {unit} is not active "
                               f"(systemctl is-active exited {live.returncode})")
    # ausearch moves its checkpoint by itself, before this script has seen a
    # single event. So it works on a staged copy, and the real checkpoint is
    # replaced only AFTER every hit is logged and the hold is on disk. If
    # anything fails before that (a crash, a full disk, a bug), the next run
    # reads the same window again: a repeated ALARM line, never a lost one.
    last_lost = os.path.join(a.state_dir, "audit.last-lost")
    ran_marker = os.path.join(a.state_dir, "audit.ran")
    last_eval = os.path.join(a.state_dir, "audit.last-eval")
    check_stamp(a, ran_marker)
    installed = os.path.join(a.state_dir, "audit.installed")
    staged = checkpoint + ".next"
    if os.path.exists(checkpoint):
        shutil.copyfile(checkpoint, staged)
    elif os.path.exists(staged):
        os.unlink(staged)  # left by a run that died before its first commit
    def start_hold():
        _write_durably(last_hit, f"{time.time():.0f}\n")

    trail_problem = check_trail(a, last_lost, start_hold)
    # A checkpoint that goes missing once one was installed is not "first run".
    first_run = not os.path.exists(checkpoint)
    if first_run and os.path.exists(installed):
        raise RuntimeError("audit checkpoint is missing but the install marker exists "
                           "(checkpoint removed or lost; not treated as a first run)")
    previous_eval = _read_text(last_eval)
    now = time.time()
    gap = None
    if previous_eval is not None:
        try:
            gap = now - float(previous_eval)
        except ValueError:
            gap = float("inf")  # an unreadable boundary is a gap too
        if gap <= a.max_gap:
            gap = None

    def commit_checkpoint():
        # The evaluation boundary is persisted even when the window was quiet
        # and no checkpoint exists, so the next run can see a gap.
        _write_durably(last_eval, f"{now:.0f}\n")
        if os.path.exists(staged):
            with open(staged, "rb") as fh:
                os.fsync(fh.fileno())
            os.replace(staged, checkpoint)
            _fsync_dir(a.state_dir)

    hit = False
    bad_count = 0
    first_bad = None
    sudoers_checked = False
    context = None

    def classify(output, seen=None, prior=()):
        nonlocal hit, bad_count, first_bad, sudoers_checked, context
        for batch in audit_batches(output):
            hits, bad = audit_scan(batch, admins)
            if bad:
                bad_count += len(bad)
                first_bad = first_bad or bad[0]
            for h in hits:
                if "sudoers" in h["keys"]:
                    if not sudoers_checked:
                        context = sudoers_context(a)
                        sudoers_checked = True
                    h["sudoers_matches_generation"] = context
                line = json.dumps(h, sort_keys=True)
                if line not in prior:
                    _log("ALARM audit " + line)
                if seen is not None:
                    seen.add(line)
                hit = True

    errors = []
    earlier = set()
    replaying = os.path.exists(replay_state)
    problem = None
    if not replaying:
        with tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace") as output:
            status, problem = run_ausearch(a.ausearch, staged, output, recent=first_run)
            replaying = status in (10, 11, 12)
            if replaying:
                try:
                    record_coverage_gap(a.state_dir, checkpoint, a.audit_log_dir, status, a.chattr)
                except (OSError, RuntimeError, ValueError) as e:
                    # Leave the checkpoint and alarms alone until the gap record is durable.
                    raise RuntimeError(f"could not record checkpoint status {status}: {e}") from e
                _write_durably(replay_state, "null")
                _log(f"ausearch checkpoint status {status}; replaying retained logs")
            try:
                classify(output, seen=earlier if replaying else None)
            except Exception:
                start_hold()
                raise

    if replaying:
        def classify_chunk(output):
            try:
                classify(output, prior=earlier)
            except Exception:
                start_hold()
                raise
            if hit or bad_count:
                start_hold()

        if hit or bad_count:
            start_hold()
        replay_audit(a, replay_state, staged, classify_chunk)
        problem = None
    if problem:
        errors.append(problem)
    if hit or bad_count or gap is not None:
        start_hold()
    # Commit only after classifying the retained window and persisting its
    # gap record. The operator's acknowledgement is independent of progress.
    if not errors:
        commit_checkpoint()
        if replaying:
            os.unlink(replay_state)
            _fsync_dir(a.state_dir)
        if os.path.exists(checkpoint) and not os.path.exists(installed):
            _write_durably(installed, f"{now:.0f}\n")
    if gap is not None:
        errors.append(f"coverage gap: {gap:.0f}s since the last evaluation (limit {a.max_gap}s); "
                      "events in between may not have been read")
    if trail_problem:
        errors.append(trail_problem)
    if bad_count:
        errors.append(f"{bad_count} unparseable line(s); first: {first_bad}")
    if errors:
        raise RuntimeError("; ".join(errors))
    # Stay red for a hold window after the last hit, then clear by itself.
    # vigil ticks every 5 min and opens after picat_dupa=2 red ticks; a red
    # stamp that lasted one 5-min evaluator period could fall between ticks.
    try:
        with open(last_hit) as fh:
            last = float(fh.read().strip() or 0)
    except FileNotFoundError:
        last = 0.0
    mark_ran(ran_marker)
    if now - last < a.hold:
        _log(f"audit: red, last hit {max(0.0, now - last):.0f}s ago (hold {a.hold}s)")
        return 1
    _log("audit: clean")
    return 0


def write_signal(path, healthy):
    # Publish the verdict atomically so Vigil never sees a transient fresh
    # mtime while a failing check is writing its signal.
    tmp = path + ".signal"
    with open(tmp, "wb"):
        pass
    if not healthy:
        os.utime(tmp, (1, 1))
    os.replace(tmp, path)


def cmd_audit_stamp(a):
    code = os.environ.get("EXIT_CODE")
    status = os.environ.get("EXIT_STATUS")
    hits = os.environ.get("SANCTA_DOCTRINE_STAMP") or os.path.join(a.state_dir, "audit-hits-clean")
    if code == "exited" and status in ("0", "1"):
        write_signal(hits, status == "0")
        write_signal(os.path.join(a.state_dir, "audit-clean"), True)
    elif not os.path.lexists(hits):
        # Repair a missing outcome so the next evaluation can proceed.
        write_signal(hits, False)
    return 0


def audit_retention_config(path):
    names = ("max_log_file", "num_logs")
    settings = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            key, _, value = line.partition("#")[0].partition("=")
            key, value = key.strip().lower(), value.strip()
            if key not in names:
                continue
            if key in settings or not re.fullmatch(r"[0-9]+", value) or int(value) == 0:
                raise ValueError(f"invalid or duplicate {key} in {path}")
            settings[key] = int(value)
    if not all(name in settings for name in names):
        raise ValueError(f"expected max_log_file and num_logs in {path}")
    return settings["max_log_file"], settings["num_logs"]


def audit_retention_deadline(a, now):
    size, count = audit_retention_config(a.auditd_conf)
    stamp = os.path.join(a.state_dir, "audit.retention-armed")
    stored = _read_text(stamp)
    # Store the first-seen epoch, both cap settings and the grace duration.
    armed_at, warmup = now, AUDIT_RETENTION_SECONDS
    if stored is not None:
        try:
            epoch, old_size, old_count, warmup = stored.split()
            armed_at = float(epoch)
            old_size, old_count, warmup = int(old_size), int(old_count), int(warmup)
            if (not 0 < armed_at <= now or min(old_size, old_count) < 1
                    or warmup not in (0, AUDIT_RETENTION_SECONDS)):
                raise ValueError
        except ValueError:
            raise ValueError(f"invalid retention arming stamp {stamp}") from None
        if (size, count) == (old_size, old_count):
            return armed_at + warmup
        cap, old_cap = size * count, old_size * old_count
        if cap > old_cap:
            armed_at, warmup = now, AUDIT_RETENTION_SECONDS
        elif cap < old_cap:
            # Persist immediate enforcement across subsequent runs at this cap.
            armed_at, warmup = now, 0
            _log(f"audit retention: cap decreased from {old_cap} to {cap} MiB; armed immediately")
    _write_durably(stamp, f"{armed_at} {size} {count} {warmup}\n")
    return armed_at + warmup


def cmd_audit_watchdog(a):
    # Serialize the arming decision and signal publication for overlapping runs.
    with open(os.path.join(a.state_dir, "audit-watchdog.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return evaluate_audit_watchdog(a)


def evaluate_audit_watchdog(a):
    state = a.state_dir
    # Allow a new installation 30 minutes to produce its first heartbeat,
    # without resetting that grace period if audit-clean later disappears.
    first_check = os.path.join(state, "audit-watchdog.started")
    mark_ran(first_check)
    heartbeat = os.path.join(state, "audit-clean")
    try:
        last_success = os.stat(heartbeat).st_mtime
    except FileNotFoundError:
        last_success = os.stat(first_check).st_mtime
    except OSError:
        last_success = 1
    now = time.time()
    healthy = 0 <= now - last_success <= 30 * 60
    if not healthy:
        _log("ALARM audit evaluator: audit-clean missing or older than 30 minutes")
    recording = not os.path.lexists(os.path.join(state, "audit.recording-unhealthy"))
    if not recording:
        _log("ALARM audit evaluator: auditd is not recording")
    write_signal(os.path.join(state, "audit-deadman-clean"), healthy and recording)

    coverage_incidents = ("audit.checkpoint-mismatch", "audit.kernel-loss")
    write_signal(os.path.join(state, "audit-gap-clean"),
                 not any(os.path.lexists(os.path.join(state, name)) for name in coverage_incidents))
    try:
        deadline = audit_retention_deadline(a, now)
        warming = now < deadline
        if warming:
            until = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(deadline))
            _log(f"audit retention warming until {until}")
        oldest = oldest_audit_record(a.audit_log_dir)
        age = now - float(oldest)
        retained = warming or age >= AUDIT_RETENTION_SECONDS
        if not retained:
            _log(f"ALARM audit retention: oldest retained record {oldest} is younger than 48 hours")
    except (OSError, RuntimeError, ValueError) as e:
        _log(f"ALARM audit retention: {e}")
        retained = False
    write_signal(os.path.join(state, "audit-retention-clean"), retained)
    return 0


def _engine(cmd: list[str], name: str) -> tuple[str | None, str | None]:
    """(stdout, error): run one engine; a failure is an error, not an exception,
    so the other engine is still read and classified."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError as e:
        return None, f"{name} could not run: {e}"
    if p.returncode != 0:
        return None, f"{name} exited {p.returncode}: {p.stderr.strip()[:300]}"
    return p.stdout, None


def cmd_bans(a) -> int:
    """Exit 0 clean, 1 a ban was found, 2 the evaluator could not evaluate,
    3 BOTH: a ban was found and some source could not be read. Every readable
    source is classified before anything is reported, so an engine error can
    never turn a real ban green (soc-bans-stamp.sh reds the paging stamp for 1
    and 3, and the health stamp for 2 and 3)."""
    if not a.state_dir or not os.path.isdir(a.state_dir):
        raise RuntimeError("no state directory (set --state-dir or STATE_DIRECTORY)")
    ran_marker = os.path.join(a.state_dir, "bans.ran")
    check_stamp(a, ran_marker, [a.stamp, a.health_stamp])
    nets = _networks([c for c in a.cidrs.split(",") if c])
    if not nets:
        raise RuntimeError("empty neverBan list")
    hits: list[dict] = []
    errors: list[str] = []
    # --limit 0: cscli returns only the newest 100 alerts by default
    # (clidecision/decisions.go, crowdsec 1.7.2); a home decision past the
    # first hundred would otherwise read clean.
    out, err = _engine([a.cscli, "decisions", "list", "-o", "json", "--limit", "0"], "cscli")
    if err:
        errors.append(err)
    else:
        h, e = crowdsec_scan(out, nets)
        hits += h
        errors += e
    out, err = _engine([a.fail2ban_client, "status", "sshd"], "fail2ban-client")
    if err:
        errors.append(err)
    else:
        h, e = fail2ban_scan(out, nets)
        hits += h
        errors += e
    for h in hits:
        _log("ALARM ban " + json.dumps(h, sort_keys=True))
    if errors:
        if not hits:
            raise RuntimeError("; ".join(errors))
        _log(f"EVALUATOR ERROR (bans): {'; '.join(errors)[:600]}")
        return 3
    mark_ran(ran_marker)
    if hits:
        return 1
    _log("bans: clean")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="soc-vigil-alarms")
    sub = ap.add_subparsers(dest="cmd", required=True)
    au = sub.add_parser("audit")
    au.add_argument("--ausearch", required=True)
    au.add_argument("--systemctl", required=True)
    au.add_argument("--auditctl", required=True)
    au.add_argument("--auditd-state-file", default="/run/audit/auditd.state")
    au.add_argument("--chattr", required=True)
    au.add_argument("--stamp", default=os.environ.get("SANCTA_DOCTRINE_STAMP"))
    # PATH:PERM:KEY, one per watch rule that must be loaded exactly; the unit
    # derives them from config.security.audit.rules.
    au.add_argument("--expect-watch", action="append", default=[])
    # Free space / inodes on the filesystem holding the audit log (nix options
    # services.soc-vigil-alarms.auditDisk.*; defaults 10 GiB warn, 5 GiB fail, 5%).
    au.add_argument("--audit-log-dir", default="/var/log/audit")
    au.add_argument("--disk-warn-bytes", type=int, default=10 * 1024 ** 3)
    au.add_argument("--disk-fail-bytes", type=int, default=5 * 1024 ** 3)
    au.add_argument("--inode-fail-percent", type=float, default=5.0)
    au.add_argument("--boot-id-file", default="/proc/sys/kernel/random/boot_id")
    # Present while a deploy's dead-man rollback is armed; annotates a loss,
    # never suppresses it.
    au.add_argument("--deploy-flag", default="/run/deploy-deadman-armed")
    # The timer runs every 5 minutes; more than this since the last evaluation
    # means events may have gone unread (reboot, stopped timer, long outage).
    # Accounts whose root execs and login sessions are hits (NAMED-ACCOUNT
    # RULE); none given = rule off.
    au.add_argument("--named-account", action="append", default=[])
    au.add_argument("--max-gap", type=int, default=600)
    au.add_argument("--require-active", action="append", default=[])
    au.add_argument("--state-dir", default=os.environ.get("STATE_DIRECTORY"))
    au.add_argument("--hold", type=int, required=True)
    # Injectable for tests; the defaults are the live paths.
    au.add_argument("--current-system", default="/run/current-system")
    au.add_argument("--etc-sudoers", default="/etc/sudoers")
    bn = sub.add_parser("bans")
    bn.add_argument("--cscli", required=True)
    bn.add_argument("--fail2ban-client", required=True)
    bn.add_argument("--cidrs", required=True)
    bn.add_argument("--state-dir", default=os.environ.get("STATE_DIRECTORY"))
    bn.add_argument("--stamp", default=os.environ.get("SANCTA_DOCTRINE_STAMP"))
    # The second outcome: an evaluator that could not evaluate (exit 2) is
    # reported here, not on the bans stamp (see soc-bans-stamp.sh).
    bn.add_argument("--health-stamp", default=os.environ.get("SOC_HEALTH_STAMP"))
    for name in ("audit-stamp", "audit-watchdog"):
        parser = sub.add_parser(name)
        parser.add_argument("--state-dir", default=os.environ.get("STATE_DIRECTORY"))
        if name == "audit-watchdog":
            parser.add_argument("--audit-log-dir", default="/var/log/audit")
            parser.add_argument("--auditd-conf", default="/etc/audit/auditd.conf")
    a = ap.parse_args(argv)
    try:
        runners = {"audit": cmd_audit, "bans": cmd_bans, "audit-stamp": cmd_audit_stamp,
                   "audit-watchdog": cmd_audit_watchdog}
        return runners[a.cmd](a)
    except Exception as e:  # noqa: BLE001 — any failure to evaluate is reported, never trusted
        _log(f"EVALUATOR ERROR ({a.cmd}): {type(e).__name__}: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
