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
    3. it is NOT the NixOS activation's /etc writer: key `sudoers`, exe a
       /nix/store perl, and the exact setup-etc.pl store path of THIS system
       generation among its argv (PROCTITLE). That is the only routine writer
       of /etc/sudoers, and it only carries a login auid when someone runs
       switch-to-configuration by hand instead of through nixos-rebuild.
    4. it is NOT the council's own key read (owner decision 2026-11-11,
       "fix A"): every /council run reads one agenix key in-session
       (council/scripts/jev-shadow.mjs, readFileSync of DEFAULT_KEY_FILE)
       and would otherwise page on each run. Exempt ONLY when ALL hold:
         key == {agenix-secrets} exactly;
         auid AND uid == the council user's uid (resolved at run time from
           the account name, since NixOS allocates it: users.users.sancta.uid
           is null on choir);
         exe is /nix/store/<hash>-nodejs-<ver>/bin/node;
         syscall is openat (x86_64 257) with O_ACCMODE == O_RDONLY;
         every PATH record names exactly the key file, either as
           <secretsDir>/<key> (/run/agenix is a symlink, and the kernel's
           PATH name is the pathname as passed) or as
           <secretsMountPoint>/<generation>/<key> (the resolved form).
       The same user reading any other secret, any other program reading
       this key, a write, or a relative path all still fire.
  Everything else in the audit log is ignored here.

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
_STORE_PERL = re.compile(r"^/nix/store/[0-9a-z]{32}-perl-[^/]+/bin/perl$")
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


def parse_events(raw_text: str) -> list[dict]:
    """Group raw audit lines into events by (timestamp, serial), in order.

    Fails CLOSED: a line that is neither a record nor an ausearch separator
    raises ValueError. If the trail's format ever stops matching (a changed
    header, a new prefix), parsing nothing would read as a clean window
    forever; raising makes it an evaluator error instead (exit 2, red).
    """
    events, bad = scan_events(raw_text)
    if bad:
        raise ValueError(bad[0])
    return events


def scan_events(raw_text: str) -> tuple[list[dict], list[str]]:
    """Like parse_events, but returns (events, unparseable-line notes) so a
    single bad line cannot hide the good events around it."""
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


def _argv(event: dict) -> list[str]:
    for rtype, f in event["records"]:
        if rtype == "PROCTITLE" and "proctitle" in f:
            decoded = _unhex(f["proctitle"]) or ""
            return [a for a in decoded.split("\x00") if a]
    return []


def _paths(event: dict) -> list[str]:
    out = []
    for rtype, f in event["records"]:
        if rtype == "PATH" and "name" in f:
            name = _unhex(f["name"])
            if name:
                out.append(name)
    return out


def is_activation_writer(event: dict, syscall: dict, keys: set[str], setup_etc: str) -> bool:
    exe = _unhex(syscall.get("exe", "")) or ""
    return (
        keys == {"sudoers"}
        and bool(setup_etc)
        and _STORE_PERL.match(exe) is not None
        and setup_etc in _argv(event)
    )


_STORE_NODE = re.compile(r"^/nix/store/[0-9a-z]{32}-nodejs-[^/]+/bin/node$")
_OPENAT_X86_64 = "257"
_ARCH_X86_64 = "c000003e"


def is_council_key_read(event: dict, syscall: dict, keys: set[str], exempt: dict | None) -> bool:
    """Rule 4 (module docstring). `exempt` = {uid, key, secrets_dir,
    secrets_mount}; None disables the exemption (everything fires)."""
    if not exempt or exempt.get("uid") is None:
        return False
    uid = str(exempt["uid"])
    if keys != {"agenix-secrets"} or syscall.get("auid") != uid or syscall.get("uid") != uid:
        return False
    if _STORE_NODE.match(_unhex(syscall.get("exe", "")) or "") is None:
        return False
    if syscall.get("arch") != _ARCH_X86_64 or syscall.get("syscall") != _OPENAT_X86_64:
        return False
    try:
        if int(syscall.get("a2", "x"), 16) & 0o3 != 0:  # O_ACCMODE: read-only only
            return False
    except ValueError:
        return False
    key = exempt["key"]
    direct = exempt["secrets_dir"].rstrip("/") + "/" + key
    resolved = re.compile("^" + re.escape(exempt["secrets_mount"].rstrip("/")) + r"/[0-9]+/" + re.escape(key) + "$")
    paths = _paths(event)
    return bool(paths) and all(p == direct or resolved.match(p) for p in paths)


def audit_hits(raw_text: str, setup_etc: str, exempt: dict | None = None) -> list[dict]:
    """PURE. Apply THE AUDIT RULE (module docstring) to `ausearch --raw` text.
    Raises ValueError on any unparseable line (see parse_events)."""
    hits, bad = audit_scan(raw_text, setup_etc, exempt)
    if bad:
        raise ValueError(bad[0])
    return hits


def audit_scan(raw_text: str, setup_etc: str, exempt: dict | None = None) -> tuple[list[dict], list[str]]:
    """PURE. THE AUDIT RULE over every parseable event, plus the bad lines."""
    events, bad = scan_events(raw_text)
    hits = []
    for ev in events:
        syscall = next((f for t, f in ev["records"] if t == "SYSCALL"), None)
        if syscall is None:
            continue
        keys = _keys(syscall) & WATCHED_KEYS
        if not keys:
            continue
        auid = syscall.get("auid")
        # A watched SYSCALL record without auid is malformed beyond anything
        # this rule was written for: fire rather than guess it was routine.
        if auid is not None and auid in UNSET_AUID:
            continue
        if is_activation_writer(ev, syscall, keys, setup_etc):
            continue
        if is_council_key_read(ev, syscall, keys, exempt):
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

    decisions_json: stdout of `cscli decisions list -o json` (`null` = none).
    fail2ban_status: stdout of `fail2ban-client status sshd`.
    Raises ValueError on input it cannot read: unreadable is not clean.
    """
    nets = _networks(cidrs)
    if not nets:
        raise ValueError("empty neverBan list")
    hits = []

    alerts = json.loads(decisions_json) if decisions_json.strip() else None
    if alerts is None:
        alerts = []
    if not isinstance(alerts, list):
        raise ValueError("cscli output is not a list")
    for alert in alerts:
        for d in (alert.get("decisions") or []):
            scope = str(d.get("scope", "")).lower()
            if scope not in ("ip", "range"):
                continue
            if _in_home(str(d.get("value", "")), nets):
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


def run_ausearch(ausearch: str, checkpoint: str) -> str:
    """Events since the checkpoint. ausearch rewrites `checkpoint` in place
    when it finds events, so cmd_audit hands it a staged COPY and commits
    that copy only after the window's outcome is recorded."""
    # --input-logs + stdin=/dev/null: ausearch reads STDIN instead of the
    # logs whenever fd 0 is a pipe (ausearch.c is_pipe), and then never saves
    # a checkpoint. Force the logs regardless of how this is started.
    base = [ausearch, "--input-logs", "--raw", "--checkpoint", checkpoint]
    # First run ever: start ten minutes back instead of replaying the whole
    # trail, so deploying this unit does not page for history.
    first = [] if os.path.exists(checkpoint) else ["--start", "recent"]

    def run(extra):
        # errors="replace": a stray non-UTF-8 byte must become one bad line
        # (reported below), not a decode error that hides the whole window.
        return subprocess.run(base + extra, capture_output=True, encoding="utf-8",
                              errors="replace", stdin=subprocess.DEVNULL)

    p = run(first)
    if p.returncode in (10, 11, 12):
        # Rotated log or a damaged checkpoint: ausearch's documented recovery
        # is to resume from the checkpoint's timestamp.
        _log(f"ausearch checkpoint status {p.returncode}; resuming from its timestamp")
        p = run(["--start", "checkpoint"])
    if p.returncode == 0:
        return p.stdout
    # 1 means "nothing found" OR an argument / file error. In --raw mode the
    # nothing-found exit is SILENT (audit 4.1.2 src/ausearch.c main():
    # `if (report_format != RPT_RAW) fprintf(stderr, "<no matches>\n")`),
    # while every error path in process_logs/process_file and option parsing
    # writes to stderr. So: exit 1 with an empty stderr is a quiet window;
    # exit 1 with anything on stderr is an evaluator failure. ("<no matches>"
    # alone is accepted too, in case a later audit prints it in raw mode.)
    err = p.stderr.strip()
    if p.returncode == 1 and err in ("", "<no matches>"):
        return ""
    raise RuntimeError(f"ausearch exited {p.returncode}: {err[:300]}")


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
    staged = checkpoint + ".next"
    if os.path.exists(checkpoint):
        shutil.copyfile(checkpoint, staged)
    elif os.path.exists(staged):
        os.unlink(staged)  # left by a run that died before its first commit
    raw = run_ausearch(a.ausearch, staged)
    now = time.time()

    def start_hold():
        _write_durably(last_hit, f"{now:.0f}\n")

    def commit_checkpoint():
        if os.path.exists(staged):
            with open(staged, "rb") as fh:
                os.fsync(fh.fileno())
            os.replace(staged, checkpoint)
            _fsync_dir(a.state_dir)

    try:
        hits, bad = audit_scan(raw, a.setup_etc, council_exemption(a))
    except Exception:
        # Could not classify at all: red for the hold, and the checkpoint
        # stays put so this window is classified again once that works.
        start_hold()
        raise
    for h in hits:
        _log("ALARM audit " + json.dumps(h, sort_keys=True))
    # A window with an unreadable line may have held a hit: it starts the
    # hold too, instead of one 5-minute red blip that picat_dupa = 2 absorbs.
    if hits or bad:
        start_hold()
    commit_checkpoint()
    if bad:
        raise ValueError(f"{len(bad)} unparseable line(s); first: {bad[0]}")
    # Stay red for a hold window after the last hit, then clear by itself.
    # vigil ticks every 5 min and opens after picat_dupa=2 red ticks; a red
    # stamp that lasted one 5-min evaluator period could fall between ticks.
    try:
        with open(last_hit) as fh:
            last = float(fh.read().strip() or 0)
    except FileNotFoundError:
        last = 0.0
    if now - last < a.hold:
        _log(f"audit: red, last hit {max(0.0, now - last):.0f}s ago (hold {a.hold}s)")
        return 1
    _log("audit: clean")
    return 0


def cmd_bans(a) -> int:
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
    if hits:
        return 1
    _log("bans: clean")
    return 0


def council_exemption(a) -> dict | None:
    """Resolve rule 4's uid from the account name. Unresolvable -> None: the
    exemption switches OFF and the read fires (noise, never blindness)."""
    if not (a.council_user and a.council_key and a.secrets_dir and a.secrets_mount):
        return None
    import pwd
    try:
        uid = pwd.getpwnam(a.council_user).pw_uid
    except KeyError:
        _log(f"council exemption off: no account {a.council_user!r}")
        return None
    return {"uid": uid, "key": a.council_key, "secrets_dir": a.secrets_dir, "secrets_mount": a.secrets_mount}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="soc-vigil-alarms")
    sub = ap.add_subparsers(dest="cmd", required=True)
    au = sub.add_parser("audit")
    au.add_argument("--ausearch", required=True)
    au.add_argument("--systemctl", required=True)
    au.add_argument("--require-active", action="append", default=[])
    au.add_argument("--state-dir", default=os.environ.get("STATE_DIRECTORY"))
    au.add_argument("--hold", type=int, required=True)
    au.add_argument("--setup-etc", required=True)
    au.add_argument("--council-user")
    au.add_argument("--council-key")
    # Paths come from the environment so no off-store path sits in ExecStart
    # (tests/execstart-path-contract.nix).
    au.add_argument("--secrets-dir", default=os.environ.get("SOC_SECRETS_DIR"))
    au.add_argument("--secrets-mount", default=os.environ.get("SOC_SECRETS_MOUNT"))
    bn = sub.add_parser("bans")
    bn.add_argument("--cscli", required=True)
    bn.add_argument("--fail2ban-client", required=True)
    bn.add_argument("--cidrs", required=True)
    a = ap.parse_args(argv)
    try:
        return cmd_audit(a) if a.cmd == "audit" else cmd_bans(a)
    except Exception as e:  # noqa: BLE001 — any failure to evaluate is reported, never trusted
        _log(f"EVALUATOR ERROR ({a.cmd}): {type(e).__name__}: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
