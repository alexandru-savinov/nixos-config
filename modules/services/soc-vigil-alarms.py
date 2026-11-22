"""soc-vigil-alarms — the two SOC alarms vigil cannot compute itself.

The SOC plan allows vigil exactly three alarms: a CrowdSec ban on a home
address, an auditd hit on /run/agenix or /etc/sudoers, and disk over
threshold. Disk is a plain vigil `disk` contract. The other two need root (the
audit log is 0700 root; cscli and fail2ban-client need the engines'
credentials), and vigil on sancta-choir runs no commands (cmdAllow = []). So
each alarm is evaluated here, by a root oneshot, and reported to vigil through
ONE file mtime that the shared stamp script writes (see
sancta-doctrine-guard-stamp.sh): exit 0 -> mtime now, anything else -> epoch+1s.

Exit codes: 0 clean, 1 ALARM, 2 the evaluator could not evaluate. 1 and 2 both
turn the stamp red: a detector that cannot see is reported, not trusted
(fail-closed; the reason is in the journal, never in the stamp).

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

EVALUATOR ERRORS (exit 2) on the audit side, besides unparseable lines:
  auditctl -s/-l unhealthy (see check_trail); ausearch exit 1 with stdout,
  exit 0 with stderr, or any other failure (the window is read again, not
  consumed); a checkpoint status 10/11/12 (the retry's events are still
  classified; the error persists until audit.checkpoint-mismatch is removed
  by an operator); a missing checkpoint once audit.installed exists (the
  marker is written when a checkpoint is first committed; a missing one
  before that is the first run); a SYSCALL record lacking arch, syscall,
  success, exe or key; a PATH record in an event with no SYSCALL record.

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
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time

WATCHED_KEYS = frozenset({"agenix-secrets", "sudoers"})
UNSET_AUID = {"4294967295", "-1", "unset"}

# Optional `node=<name> ` prefix: auditd writes it when name_format != none.
_HEADER = re.compile(r"^(?:node=\S+ )?type=(\S+) msg=audit\(([0-9.]+):([0-9]+)\):\s?(.*)$")
# The only non-record lines ausearch prints: its event separator and the
# legacy empty-result note.
_SEPARATORS = frozenset({"", "----", "<no matches>"})
_FIELD = re.compile(r'([A-Za-z0-9_-]+)=("[^"]*"|\S+)')
# What every SYSCALL record must carry for the rules to read it. auid is not
# here: a watched SYSCALL without auid is an existing hit (audit_scan).
_SYSCALL_REQUIRED = ("arch", "syscall", "success", "exe", "key")
_HEX = re.compile(r"^(?:[0-9A-Fa-f]{2})+$")


# ── audit: raw record parsing ──────────────────────────────────────────────

def _fields(body: str) -> dict:
    # ENRICHED log_format appends interpreted fields after a GS (0x1d)
    # separator. Only the kernel's raw half is trusted here.
    raw = body.split("\x1d", 1)[0]
    return {m.group(1): m.group(2) for m in _FIELD.finditer(raw)}


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




def audit_hits(raw_text: str) -> list[dict]:
    """PURE. Apply THE AUDIT RULE (module docstring) to `ausearch --raw` text.
    Raises ValueError on any unparseable or malformed record (see scan_events, audit_scan)."""
    hits, bad = audit_scan(raw_text)
    if bad:
        raise ValueError(bad[0])
    return hits


def audit_scan(raw_text: str) -> tuple[list[dict], list[str]]:
    """PURE. THE AUDIT RULE over every parseable event, plus the bad lines."""
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


def home_bans(decisions_json: str, fail2ban_status: str, cidrs: list[str]) -> list[dict]:
    """PURE. Apply THE BAN RULE (module docstring).

    decisions_json: stdout of `cscli decisions list -o json` (`null` or `[]` = none).
    fail2ban_status: stdout of `fail2ban-client status sshd`.
    Raises ValueError on input it cannot read: unreadable is not clean.
    """
    nets = _networks(cidrs)
    if not nets:
        raise ValueError("empty neverBan list")
    hits = []

    # Only the documented "no decisions" answers are clean: JSON null or [].
    # Empty output, or an entry without the fields read below, is unreadable.
    if not decisions_json.strip():
        raise ValueError("cscli output is empty")
    alerts = json.loads(decisions_json)
    if alerts is None:
        alerts = []
    if not isinstance(alerts, list):
        raise ValueError("cscli output is not a list")
    for alert in alerts:
        if not isinstance(alert, dict) or not isinstance(alert.get("decisions"), list):
            raise ValueError(f"cscli alert without a decisions list: {str(alert)[:80]}")
        for d in alert["decisions"]:
            if not isinstance(d, dict) or "scope" not in d or "value" not in d:
                raise ValueError(f"cscli decision without scope/value: {str(d)[:80]}")
            if not all(isinstance(d[k], str) and d[k].strip() for k in ("scope", "value")):
                raise ValueError(f"cscli decision with a null, non-string or empty scope/value: {str(d)[:80]}")
            scope = d["scope"].lower()
            if scope not in ("ip", "range"):
                continue
            if _in_home(str(d["value"]), nets):
                hits.append({"engine": "crowdsec", "value": d["value"], "type": d.get("type")})

    banned_line = None
    for line in fail2ban_status.splitlines():
        if "Banned IP list:" in line:
            banned_line = line.split("Banned IP list:", 1)[1]
    if banned_line is None:
        raise ValueError("fail2ban status has no 'Banned IP list' line")
    for ip in banned_line.split():
        if _in_home(ip, nets):
            hits.append({"engine": "fail2ban", "value": ip, "type": "ban"})
    return hits


# ── runners (impure: exec, state files) ─────────────────────────────────────

def _log(msg: str) -> None:
    print(msg, flush=True)


def run_ausearch(ausearch: str, checkpoint: str, first_run: bool = False) -> tuple[str, list[str], bool]:
    """Events since the checkpoint: (stdout, problems, checkpoint_mismatch).

    ausearch rewrites `checkpoint` in place when it finds events, so cmd_audit
    hands it a staged COPY and commits that copy only after the window's
    outcome is recorded. stdout is always returned, even next to a problem, so
    the events in it are still classified; a non-empty `problems` means the
    window cannot be called clean and must not be consumed.
    """
    # --input-logs + stdin=/dev/null: ausearch reads STDIN instead of the
    # logs whenever fd 0 is a pipe (ausearch.c is_pipe), and then never saves
    # a checkpoint. Force the logs regardless of how this is started.
    base = [ausearch, "--input-logs", "--raw", "--checkpoint", checkpoint]
    # First run ever (no checkpoint and no install marker, decided by the
    # caller): start ten minutes back instead of replaying the whole trail, so
    # deploying this unit does not page for history.
    first = ["--start", "recent"] if first_run else []

    def run(extra):
        # errors="replace": a stray non-UTF-8 byte must become one bad line
        # (reported below), not a decode error that hides the whole window.
        return subprocess.run(base + extra, capture_output=True, encoding="utf-8",
                              errors="replace", stdin=subprocess.DEVNULL)

    problems: list[str] = []
    mismatch = False
    earlier = ""  # what the first attempt printed before a checkpoint retry
    p = run(first)
    if p.returncode in (10, 11, 12):
        earlier = p.stdout
        # Rotated log or a damaged checkpoint. The timestamp retry still reads
        # the window (its events are classified and any hit is an ALARM), but
        # the mismatch itself is an evaluator error until it is reconciled.
        mismatch = True
        problems.append(f"ausearch checkpoint status {p.returncode}: checkpoint does not match the logs")
        _log(f"ausearch checkpoint status {p.returncode}; reading from its timestamp")
        p = run(["--start", "checkpoint"])
    err = p.stderr.strip()
    if p.returncode == 0:
        # A successful ausearch has nothing to say on stderr.
        if err:
            problems.append(f"ausearch exited 0 with stderr: {err[:300]}")
    elif p.returncode == 1 and not p.stdout.strip() and err in ("", "<no matches>"):
        # 1 means "nothing found" OR an argument / file error. In --raw mode
        # the nothing-found exit is SILENT (audit 4.1.2 src/ausearch.c main():
        # `if (report_format != RPT_RAW) fprintf(stderr, "<no matches>\n")`),
        # while every error path in process_logs/process_file and option
        # parsing writes to stderr. So: exit 1 with empty stdout and empty
        # stderr is a quiet window. ("<no matches>" alone is accepted too, in
        # case a later audit prints it in raw mode.)
        pass
    elif p.returncode == 1 and p.stdout.strip():
        problems.append(f"ausearch exited 1 with output on stdout: {p.stdout.strip()[:80]!r}")
    else:
        problems.append(f"ausearch exited {p.returncode}: {err[:300]}")
    out = p.stdout
    if earlier:
        # Keep the first attempt's records next to the retry's, once each.
        seen, lines = set(), []
        for line in (earlier + "\n" + out).split("\n"):
            if line.strip() and line in seen:
                continue
            seen.add(line)
            lines.append(line)
        out = "\n".join(lines)
    return out, problems, mismatch


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


def _auditctl(a, flag: str) -> str:
    p = subprocess.run([a.auditctl, flag], capture_output=True, text=True,
                       stdin=subprocess.DEVNULL)
    if p.returncode != 0:
        raise RuntimeError(f"auditctl {flag} exited {p.returncode}: {p.stderr.strip()[:300]}")
    return p.stdout


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


def loaded_watches(text: str) -> set[tuple[str, frozenset, str]]:
    """PURE. (path, perm letters, key) for every watch rule in `auditctl -l`
    output, in either printed form: `-w PATH -p PERM -k KEY` or
    `-a ... -F path=PATH|dir=PATH -F perm=PERM -F key=KEY`. A rule missing
    its path, perm or key is not a watch for this purpose."""
    out = set()
    for line in text.splitlines():
        t = line.split()
        path = perm = key = None
        for i, tok in enumerate(t):
            nxt = t[i + 1] if i + 1 < len(t) else None
            if tok == "-w":
                path = nxt
            elif tok == "-p":
                perm = nxt
            elif tok == "-k":
                key = nxt
            elif tok == "-F" and nxt and "=" in nxt:
                name, _, value = nxt.partition("=")
                if name in ("path", "dir"):
                    path = value
                elif name == "perm":
                    perm = value
                elif name == "key":
                    key = value
        if path and perm and key:
            out.add((path, frozenset(perm), key))
    return out


def parse_expected_watch(spec: str) -> tuple[str, frozenset, str]:
    path, perm, key = spec.rsplit(":", 2)
    if not (path.startswith("/") and perm and key):
        raise ValueError(f"bad --expect-watch {spec!r} (want PATH:PERM:KEY)")
    return path, frozenset(perm), key


def check_trail(a, last_lost_path: str, start_hold) -> str | None:
    """Trail health, checked on every evaluation before a quiet window is
    accepted: auditing enabled, a live auditd pid, exactly the expected watch
    rules loaded, and a lost counter that never moves except at a boot.
    Returns a problem to report after the window was read (the loss counter
    moved); raises when the trail cannot record."""
    enabled, lost, pid = audit_status(_auditctl(a, "-s"))
    if enabled not in (1, 2):
        raise RuntimeError(f"audit trail not recording: auditctl -s enabled={enabled}")
    if pid == 0:
        raise RuntimeError("audit trail not recording: no auditd registered with the kernel (pid 0)")
    if not a.expect_watch:
        raise RuntimeError("no --expect-watch given: cannot prove the watch rules are loaded")
    loaded = loaded_watches(_auditctl(a, "-l"))
    missing = [w for w in map(parse_expected_watch, a.expect_watch) if w not in loaded]
    if missing:
        raise RuntimeError("audit watch rule(s) not loaded as expected: "
                           + ", ".join(f"{p} -p {''.join(sorted(m))} -k {k}" for p, m, k in missing))
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
        # events, a fall is state this check cannot trust. Hold red, then
        # record the new value so the hold carries the signal.
        problem = (f"audit trail lost {lost - previous} event(s) since the last evaluation"
                   if lost > previous else
                   f"audit lost counter fell from {previous} to {lost} within one boot")
        start_hold()
    if previous != lost or stored is None or not stored.startswith(boot):
        _write_durably(last_lost_path, f"{boot} {lost}\n")
    return problem


def check_stamp(a, ran_marker: str) -> None:
    """The stamp is the only thing vigil reads. Once a run has completed here
    (`ran_marker`), a missing stamp is an evaluator error: this run exits 2,
    the stamp script writes the stamp already invalid, and vigil reads red
    instead of an absent file (which it reads as unreadable, a note)."""
    if not a.stamp:
        raise RuntimeError("no stamp path (set --stamp or SANCTA_DOCTRINE_STAMP)")
    if os.path.exists(ran_marker) and not os.path.lexists(a.stamp):
        raise RuntimeError(f"outcome stamp {a.stamp} is missing after an earlier run")
    # Invalidate BEFORE evaluating (epoch + 1s). Only a clean run's stamp
    # script makes it fresh again, so a run that dies, or whose stamp writer
    # fails (even to remove the file), can never leave an earlier fresh stamp
    # behind. If even this cannot be done the run is an error.
    if os.path.lexists(a.stamp):
        try:
            os.utime(a.stamp, (1, 1))
        except OSError as e:
            raise RuntimeError(f"cannot invalidate outcome stamp {a.stamp}: {e}") from e


def mark_ran(ran_marker: str) -> None:
    if not os.path.exists(ran_marker):
        _write_durably(ran_marker, f"{time.time():.0f}\n")


def cmd_audit(a) -> int:
    # systemd's StateDirectory= exports STATE_DIRECTORY; tests pass --state-dir.
    if not a.state_dir or not os.path.isdir(a.state_dir):
        raise RuntimeError("no state directory (set --state-dir or STATE_DIRECTORY)")
    checkpoint = os.path.join(a.state_dir, "audit.checkpoint")
    last_hit = os.path.join(a.state_dir, "audit.last-hit")
    # A quiet window is only evidence when the trail can record. auditd down,
    # or audit-rules-nixos failed (its ExecStopPost deletes EVERY rule), also
    # yields a silent exit 1 from ausearch; without this gate that blind state
    # would read clean forever. Not proven here: rules deleted by hand while
    # both units stay active (needs root, and root can stop auditd anyway).
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
    mismatch_flag = os.path.join(a.state_dir, "audit.checkpoint-mismatch")
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
    raw, problems, mismatch = run_ausearch(a.ausearch, staged, first_run)
    now = time.time()
    previous_eval = _read_text(last_eval)
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

    try:
        hits, bad = audit_scan(raw)
        if any("sudoers" in h["keys"] for h in hits):
            context = sudoers_context(a)
            for h in hits:
                if "sudoers" in h["keys"]:
                    h["sudoers_matches_generation"] = context
    except Exception:
        # Could not classify at all: red for the hold, and the checkpoint
        # stays put so this window is classified again once that works.
        start_hold()
        raise
    for h in hits:
        _log("ALARM audit " + json.dumps(h, sort_keys=True))
    # A window with an unreadable line may have held a hit: it starts the
    # hold too, instead of one 5-minute red blip that picat_dupa = 2 absorbs.
    if hits or bad or mismatch or gap is not None:
        start_hold()
    if mismatch:
        # Stays an evaluator error until an operator reconciles it (reads the
        # window by hand, then removes this file).
        _write_durably(mismatch_flag, f"{now:.0f}\n")
    # An ausearch anomaly leaves the window unconsumed: it is read again, a
    # repeated ALARM line rather than a lost one. A mismatch is the exception:
    # the retry's checkpoint is committed and the flag above carries the error.
    if not [p for p in problems if "checkpoint status" not in p]:
        commit_checkpoint()
        if os.path.exists(checkpoint) and not os.path.exists(installed):
            _write_durably(installed, f"{now:.0f}\n")
    errors = list(problems)
    if gap is not None:
        errors.append(f"coverage gap: {gap:.0f}s since the last evaluation (limit {a.max_gap}s); "
                      "events in between may not have been read")
    if trail_problem:
        errors.append(trail_problem)
    if bad:
        errors.append(f"{len(bad)} unparseable line(s); first: {bad[0]}")
    if os.path.exists(mismatch_flag) and not mismatch:
        errors.append(f"audit checkpoint mismatch not reconciled (remove {mismatch_flag} after checking the window)")
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


def cmd_bans(a) -> int:
    if not a.state_dir or not os.path.isdir(a.state_dir):
        raise RuntimeError("no state directory (set --state-dir or STATE_DIRECTORY)")
    ran_marker = os.path.join(a.state_dir, "bans.ran")
    check_stamp(a, ran_marker)
    # --limit 0: cscli returns only the newest 100 alerts by default
    # (clidecision/decisions.go, crowdsec 1.7.2); a home decision past the
    # first hundred would otherwise read clean.
    p1 = subprocess.run([a.cscli, "decisions", "list", "-o", "json", "--limit", "0"],
                        capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if p1.returncode != 0:
        raise RuntimeError(f"cscli exited {p1.returncode}: {p1.stderr.strip()[:300]}")
    p2 = subprocess.run([a.fail2ban_client, "status", "sshd"], capture_output=True, text=True,
                        stdin=subprocess.DEVNULL)
    if p2.returncode != 0:
        raise RuntimeError(f"fail2ban-client exited {p2.returncode}: {p2.stderr.strip()[:300]}")
    hits = home_bans(p1.stdout, p2.stdout, [c for c in a.cidrs.split(",") if c])
    for h in hits:
        _log("ALARM ban " + json.dumps(h, sort_keys=True))
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
    au.add_argument("--stamp", default=os.environ.get("SANCTA_DOCTRINE_STAMP"))
    # PATH:PERM:KEY, one per watch rule that must be loaded exactly; the unit
    # derives them from config.security.audit.rules.
    au.add_argument("--expect-watch", action="append", default=[])
    au.add_argument("--boot-id-file", default="/proc/sys/kernel/random/boot_id")
    # The timer runs every 5 minutes; more than this since the last evaluation
    # means events may have gone unread (reboot, stopped timer, long outage).
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
    a = ap.parse_args(argv)
    try:
        return cmd_audit(a) if a.cmd == "audit" else cmd_bans(a)
    except Exception as e:  # noqa: BLE001 — any failure to evaluate is reported, never trusted
        _log(f"EVALUATOR ERROR ({a.cmd}): {type(e).__name__}: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
