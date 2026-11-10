"""Fixture-driven tests for modules/services/soc-vigil-alarms.py.

Every rule is driven in BOTH directions: a fixture that must fire and its
nearest neighbour that must not. The audit fixtures are hand-built in the
kernel's raw record format (what `ausearch --raw` prints): one SYSCALL record,
CWD, PATH and PROCTITLE records sharing a msg=audit(<ts>:<serial>) stamp,
PROCTITLE hex-encoded with NUL-separated argv, and the ENRICHED half after a
GS (0x1d) byte. They were not captured from choir's trail (root-only).

Run: python3 tests/test_soc_vigil_alarms.py   (or pytest)
The flake check `soc-vigil-alarms` runs it with SOC_VIGIL_ALARMS pointing at
the script's store path.
"""
import importlib.util
import json
import os
import stat
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get(
    "SOC_VIGIL_ALARMS",
    os.path.join(HERE, "..", "modules", "services", "soc-vigil-alarms.py"),
)
_spec = importlib.util.spec_from_file_location("soc_vigil_alarms", SCRIPT)
sva = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sva)

H = "a" * 32
SETUP_ETC = f"/nix/store/{'r' * 32}-setup-etc.pl"
OTHER_SETUP_ETC = f"/nix/store/{'x' * 32}-setup-etc.pl"
PERL = f"/nix/store/{'p' * 32}-perl-5.40.0/bin/perl"
CAT = f"/nix/store/{H}-coreutils-9.8/bin/cat"
AGE = f"/nix/store/{'g' * 32}-rage-0.11.1/bin/rage"
NEVER_BAN = [
    "100.64.0.0/10", "fd7a:115c:a1e0::/48", "127.0.0.0/8", "::1/128",
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
]
UNSET = "4294967295"


def hexargv(*argv):
    return "\x00".join(argv).encode().hex().upper()


def event(serial, *, key, auid, exe, comm, path, argv, success="yes", syscall=257, enriched=True):
    stamp = f"msg=audit(1762790400.{serial % 1000:03d}:{serial})"
    # The kernel prints a key quoted, as (null), or hex when it holds several
    # keys joined by SOH. Uppercase-hex fixtures are passed through as-is.
    raw_key = key == "(null)" or all(c in "0123456789ABCDEF" for c in key)
    keyf = key if raw_key else f'"{key}"'
    sysc = (
        f"type=SYSCALL {stamp}: arch=c000003e syscall={syscall} success={success} exit=3 "
        f"a0=ffffff9c a1=55d0c2 a2=0 a3=0 items=1 ppid=2201 pid={3000 + serial} auid={auid} "
        f"uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts0 ses=4 "
        f'comm="{comm}" exe="{exe}" subj=unconfined key={keyf}'
    )
    if enriched:
        sysc += '\x1dARCH=x86_64 SYSCALL=openat AUID="alex" UID="root" GID="root"'
    return "\n".join([
        sysc,
        f'type=CWD {stamp}: cwd="/root"',
        f'type=PATH {stamp}: item=0 name="{path}" inode=1234 dev=00:1a mode=0100400 '
        f"ouid=0 ogid=0 rdev=00:00 nametype=NORMAL cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0 cap_frootid=0",
        f"type=PROCTITLE {stamp}: proctitle={hexargv(*argv)}",
    ])


def login_reads_agenix(serial=1, auid="1000", success="yes"):
    return event(serial, key="agenix-secrets", auid=auid, exe=CAT, comm="cat",
                 path="/run/agenix.d/3/example-one", success=success,
                 argv=["cat", "/run/agenix/example-one"])


def service_reads_agenix(serial=2):
    return event(serial, key="agenix-secrets", auid=UNSET, exe=AGE, comm="rage",
                 path="/run/agenix.d/3/example-two", argv=[AGE, "--decrypt"])


def activation_writes_sudoers(serial=3, auid="1000", setup_etc=SETUP_ETC, exe=PERL):
    return event(serial, key="sudoers", auid=auid, exe=exe, comm="perl",
                 path="/etc/sudoers", syscall=82,
                 argv=[f"/nix/store/{'e' * 32}-perl-5.40.0-env/bin/perl", setup_etc,
                       f"/nix/store/{'c' * 32}-etc/etc"])


def classify(*events):
    return sva.audit_hits("\n----\n".join(events) + "\n", SETUP_ETC)


class AuditRule(unittest.TestCase):
    # ── positive arms ──
    def test_login_read_of_agenix_fires(self):
        hits = classify(login_reads_agenix())
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["keys"], ["agenix-secrets"])
        self.assertEqual(hits[0]["auid"], "1000")
        self.assertEqual(hits[0]["paths"], ["/run/agenix.d/3/example-one"])

    def test_failed_attempt_by_login_fires(self):
        self.assertEqual(len(classify(login_reads_agenix(success="no"))), 1)

    def test_root_login_auid_zero_fires(self):
        self.assertEqual(len(classify(login_reads_agenix(auid="0"))), 1)

    def test_agent_session_auid_fires(self):
        # Sancta's own sessions carry auid 993 (a login, not a service).
        self.assertEqual(len(classify(login_reads_agenix(auid="993"))), 1)

    def test_login_edit_of_sudoers_fires(self):
        vi = event(4, key="sudoers", auid="1000", exe=f"/nix/store/{H}-vim-9.1/bin/vim",
                   comm="vim", path="/etc/sudoers", argv=["vim", "/etc/sudoers"])
        self.assertEqual(len(classify(vi)), 1)

    def test_activation_with_foreign_setup_etc_fires(self):
        # Same perl, a setup-etc.pl that is not this generation's: not exempt.
        self.assertEqual(len(classify(activation_writes_sudoers(setup_etc=OTHER_SETUP_ETC))), 1)

    def test_activation_args_from_non_store_perl_fires(self):
        self.assertEqual(len(classify(activation_writes_sudoers(exe="/tmp/perl"))), 1)

    def test_activation_exemption_does_not_cover_agenix(self):
        ev = event(5, key="agenix-secrets", auid="1000", exe=PERL, comm="perl",
                   path="/run/agenix.d/3/x", argv=["perl", SETUP_ETC, "/etc"])
        self.assertEqual(len(classify(ev)), 1)

    def test_hex_multikey_containing_sudoers_fires(self):
        key = "identity\x01sudoers".encode().hex().upper()
        ev = event(6, key=key, auid="1000", exe=CAT, comm="tee", path="/etc/sudoers",
                   argv=["tee", "/etc/sudoers"])
        hits = classify(ev)
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["keys"], ["sudoers"])

    def test_raw_format_without_enrichment_fires(self):
        self.assertEqual(len(sva.audit_hits(
            event(7, key="agenix-secrets", auid="1000", exe=CAT, comm="cat",
                  path="/run/agenix.d/3/a", argv=["cat"], enriched=False), SETUP_ETC)), 1)

    def test_missing_auid_fires(self):
        ev = login_reads_agenix().replace(" auid=1000 ", " ", 1)
        self.assertEqual(len(classify(ev)), 1)

    # ── negative arms ──
    def test_service_read_of_agenix_is_silent(self):
        self.assertEqual(classify(service_reads_agenix()), [])

    def test_activation_write_to_sudoers_with_login_auid_is_silent(self):
        self.assertEqual(classify(activation_writes_sudoers()), [])

    def test_activation_write_to_sudoers_via_systemd_run_is_silent(self):
        self.assertEqual(classify(activation_writes_sudoers(auid=UNSET)), [])

    def test_unwatched_keys_are_silent(self):
        for key, path in (("sshd-config", "/etc/ssh/sshd_config"), ("identity", "/etc/passwd"),
                          ("root-exec", "/run/current-system/sw/bin/ls")):
            ev = event(8, key=key, auid="1000", exe=CAT, comm="x", path=path, argv=["x"])
            self.assertEqual(classify(ev), [], key)

    def test_unkeyed_event_is_silent(self):
        ev = event(9, key="(null)", auid="1000", exe=CAT, comm="cat", path="/etc/hosts", argv=["cat"])
        self.assertEqual(classify(ev), [])

    def test_key_only_in_enriched_half_is_ignored(self):
        ev = event(10, key="(null)", auid="1000", exe=CAT, comm="cat", path="/etc/hosts",
                   argv=["cat"]).replace('UID="root"', 'UID="root" key="sudoers"', 1)
        self.assertEqual(classify(ev), [])

    def test_node_prefixed_records_parse(self):
        ev = "\n".join("node=choir " + ln for ln in login_reads_agenix().split("\n"))
        self.assertEqual(len(sva.audit_hits(ev, SETUP_ETC)), 1)

    def test_unparseable_line_fails_closed(self):
        with self.assertRaises(ValueError):
            sva.audit_hits("event: something audit 4.2 might print\n", SETUP_ETC)
        with self.assertRaises(ValueError):
            classify(service_reads_agenix(), "typ=SYSCALL msg=audit(1.0:1): key=\"sudoers\"")

    def test_empty_and_noise_are_silent(self):
        self.assertEqual(sva.audit_hits("", SETUP_ETC), [])
        self.assertEqual(sva.audit_hits("<no matches>\n----\n", SETUP_ETC), [])

    # ── mixed batch: only the login event survives ──
    def test_mixed_batch(self):
        hits = classify(service_reads_agenix(11), activation_writes_sudoers(12),
                        login_reads_agenix(13), service_reads_agenix(14))
        self.assertEqual([h["serial"] for h in hits], ["13"])


def f2b(*ips):
    return (
        "Status for the jail: sshd\n|- Filter\n|  |- Currently failed:\t0\n"
        "|  |- Total failed:\t12\n|  `- Journal matches:\t_SYSTEMD_UNIT=sshd.service + _COMM=sshd\n"
        f"`- Actions\n   |- Currently banned:\t{len(ips)}\n   |- Total banned:\t{len(ips)}\n"
        f"   `- Banned IP list:\t{' '.join(ips)}\n"
    )


def decisions(*pairs):
    return json.dumps([
        {"id": i + 1, "scenario": "crowdsecurity/ssh-bf",
         "decisions": [{"id": i + 1, "origin": "crowdsec", "scope": scope, "value": value,
                        "type": "ban", "duration": "3h59m"}]}
        for i, (scope, value) in enumerate(pairs)
    ])


class BanRule(unittest.TestCase):
    def test_crowdsec_decision_on_tailnet_fires(self):
        hits = sva.home_bans(decisions(("Ip", "100.64.12.7")), f2b(), NEVER_BAN)
        self.assertEqual([(h["engine"], h["value"]) for h in hits], [("crowdsec", "100.64.12.7")])

    def test_crowdsec_decision_on_public_ip_is_silent(self):
        self.assertEqual(sva.home_bans(decisions(("Ip", "203.0.113.7"), ("Ip", "198.51.100.1")),
                                       f2b(), NEVER_BAN), [])

    def test_crowdsec_range_overlapping_home_fires(self):
        self.assertEqual(len(sva.home_bans(decisions(("Range", "100.64.0.0/24")), f2b(), NEVER_BAN)), 1)
        self.assertEqual(len(sva.home_bans(decisions(("Range", "0.0.0.0/0")), f2b(), NEVER_BAN)), 1)

    def test_crowdsec_public_range_is_silent(self):
        self.assertEqual(sva.home_bans(decisions(("Range", "203.0.113.0/24")), f2b(), NEVER_BAN), [])

    def test_crowdsec_tailnet_ipv6_fires(self):
        self.assertEqual(len(sva.home_bans(decisions(("Ip", "fd7a:115c:a1e0::5")), f2b(), NEVER_BAN)), 1)

    def test_crowdsec_non_ip_scope_ignored(self):
        self.assertEqual(sva.home_bans(decisions(("Country", "RO")), f2b(), NEVER_BAN), [])

    def test_crowdsec_null_means_none(self):
        self.assertEqual(sva.home_bans("null\n", f2b(), NEVER_BAN), [])

    def test_fail2ban_ban_on_lan_fires(self):
        hits = sva.home_bans("null", f2b("203.0.113.9", "192.168.1.20"), NEVER_BAN)
        self.assertEqual([(h["engine"], h["value"]) for h in hits], [("fail2ban", "192.168.1.20")])

    def test_fail2ban_ipv4_mapped_tailnet_fires(self):
        self.assertEqual(len(sva.home_bans("null", f2b("::ffff:100.100.1.1"), NEVER_BAN)), 1)

    def test_fail2ban_public_only_is_silent(self):
        self.assertEqual(sva.home_bans("null", f2b("203.0.113.9", "2001:db8::1"), NEVER_BAN), [])

    def test_boundary_just_outside_cgnat_is_silent(self):
        self.assertEqual(sva.home_bans(decisions(("Ip", "100.128.0.1")), f2b("100.63.255.255"), NEVER_BAN), [])

    def test_unreadable_inputs_raise(self):
        with self.assertRaises(ValueError):
            sva.home_bans("null", "garbage", NEVER_BAN)
        with self.assertRaises(ValueError):
            sva.home_bans('{"not": "a list"}', f2b(), NEVER_BAN)
        with self.assertRaises(ValueError):
            sva.home_bans("null", f2b(), [])
        with self.assertRaises(ValueError):
            sva.home_bans(decisions(("Ip", "not-an-ip")), f2b(), NEVER_BAN)


# What `ausearch --raw` really does on a quiet window: exit 1, print nothing.
# (audit 4.1.2 src/ausearch.c: "<no matches>" is suppressed for RPT_RAW.)
QUIET = "exit 1\n"


def slurp(path):
    with open(path) as fh:
        return fh.read()


def fake(dirpath, name, body):
    path = os.path.join(dirpath, name)
    with open(path, "w") as fh:
        fh.write("#!/bin/sh\n" + body)
    os.chmod(path, stat.S_IRWXU)
    return path


class Runners(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.sd = os.path.join(self.d, "state")
        os.mkdir(self.sd)
        self.cp = os.path.join(self.sd, "audit.checkpoint")
        self.last = os.path.join(self.sd, "audit.last-hit")
        self.log = os.path.join(self.d, "args")

    def ausearch(self, script):
        return fake(self.d, "ausearch", f'echo "$@" >> {self.log}\n' + script)

    def audit(self, ausearch, hold=900, systemctl_exit=0, inactive=()):
        # Behaves like the real one: with several units it exits 0 if ANY is
        # active, so a gate that asks about both at once is caught below.
        dead = " ".join(inactive)
        systemctl = fake(self.d, "systemctl", (
            f'echo "$@" >> {self.log}.systemctl\n'
            f'[ {systemctl_exit} -ne 0 ] && exit {systemctl_exit}\n'
            'shift 3\n'  # is-active --quiet --
            'for u in "$@"; do case " ' + dead + ' " in *" $u "*) ;; *) exit 0;; esac; done\n'
            'exit 3\n'
        ))
        return sva.main(["audit", "--ausearch", ausearch, "--systemctl", systemctl,
                         "--require-active", "auditd.service", "--require-active", "audit-rules-nixos.service",
                         "--state-dir", self.sd, "--hold", str(hold), "--setup-etc", SETUP_ETC])

    def test_quiet_window_with_dead_trail_is_error(self):
        # auditd stopped / rules unloaded: ausearch is just as silent, so the
        # quiet window must NOT read clean.
        self.assertEqual(self.audit(self.ausearch(QUIET), systemctl_exit=3), 2)
        self.assertIn("is-active --quiet -- auditd.service", slurp(self.log + ".systemctl"))
        self.assertFalse(os.path.exists(self.log), "ausearch must not run on a dead trail")

    def test_rules_unit_failed_while_auditd_runs_is_error(self):
        # audit-rules-nixos failed => every rule deleted, auditd still up.
        self.assertEqual(self.audit(self.ausearch(QUIET), inactive=("audit-rules-nixos.service",)), 2)
        self.assertFalse(os.path.exists(self.log), "ausearch must not run on a dead trail")

    def test_auditd_down_while_rules_unit_active_is_error(self):
        self.assertEqual(self.audit(self.ausearch(QUIET), inactive=("auditd.service",)), 2)

    def test_live_trail_quiet_window_is_clean(self):
        self.assertEqual(self.audit(self.ausearch(QUIET), systemctl_exit=0), 0)

    def test_no_required_units_is_error(self):
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        self.assertEqual(sva.main(["audit", "--ausearch", self.ausearch(QUIET), "--systemctl", systemctl,
                                   "--state-dir", self.sd, "--hold", "900", "--setup-etc", SETUP_ETC]), 2)

    def test_missing_state_dir_is_error(self):
        a = self.ausearch(QUIET)
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        self.assertEqual(sva.main(["audit", "--ausearch", a, "--systemctl", systemctl,
                                   "--require-active", "auditd.service",
                                   "--state-dir", os.path.join(self.d, "nope"),
                                   "--hold", "900", "--setup-etc", SETUP_ETC]), 2)

    def test_silent_exit_one_is_clean_and_first_run_starts_recent(self):
        a = self.ausearch(QUIET)
        self.assertEqual(self.audit(a), 0)
        args = slurp(self.log)
        self.assertIn("--start recent", args)
        # Logs are forced even if fd 0 were a pipe (else ausearch reads stdin).
        self.assertIn("--input-logs", args)

    def test_legacy_no_matches_message_is_clean(self):
        self.assertEqual(self.audit(self.ausearch('echo "<no matches>" >&2; exit 1\n')), 0)

    def test_quiet_windows_never_turn_red(self):
        a = self.ausearch(QUIET)
        for _ in range(4):
            self.assertEqual(self.audit(a), 0)

    def test_exit_one_without_no_matches_is_error(self):
        a = self.ausearch('echo "Error opening /var/log/audit/audit.log" >&2; exit 1\n')
        self.assertEqual(self.audit(a), 2)

    def test_checkpoint_error_resumes_from_timestamp(self):
        open(self.cp, "w").close()
        a = self.ausearch('case "$*" in *"--start checkpoint"*) exit 1;; esac\nexit 12\n')
        self.assertEqual(self.audit(a), 0)
        args = slurp(self.log).splitlines()
        self.assertEqual(len(args), 2)
        self.assertNotIn("--start recent", args[0])
        self.assertIn("--start checkpoint", args[1])

    def test_hit_turns_red_holds_then_clears(self):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(login_reads_agenix() + "\n")
        hit = self.ausearch(f"cat {fixture}\n")
        self.assertEqual(self.audit(hit), 1)
        quiet = self.ausearch(QUIET)
        # Next window: no new events, still inside the hold -> still red.
        self.assertEqual(self.audit(quiet), 1)
        # Hold elapsed -> clears by itself, no acknowledgement needed.
        with open(self.last, "w") as fh:
            fh.write(f"{time.time() - 901:.0f}\n")
        self.assertEqual(self.audit(quiet), 0)

    def test_format_drift_turns_red(self):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write("unrecognised audit output\n")
        self.assertEqual(self.audit(self.ausearch(f"cat {fixture}\n")), 2)

    def test_routine_events_never_turn_red(self):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(service_reads_agenix() + "\n" + activation_writes_sudoers() + "\n")
        self.assertEqual(self.audit(self.ausearch(f"cat {fixture}\n")), 0)
        self.assertFalse(os.path.exists(self.last))

    def bans(self, cscli_body, f2b_body):
        guard = 'case " $* " in *" --limit 0 "*) ;; *) echo "default limit 100" >&2; exit 3;; esac\n'
        return sva.main(["bans", "--cscli", fake(self.d, "cscli", guard + cscli_body),
                         "--fail2ban-client", fake(self.d, "f2b", f2b_body),
                         "--cidrs", ",".join(NEVER_BAN)])

    def test_bans_runner_arms(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        self.assertEqual(self.bans("echo null\n", f"cat <<'E'\n{status}E\n"), 0)
        self.assertEqual(self.bans(f"cat <<'E'\n{decisions(('Ip', '100.64.1.1'))}\nE\n",
                                   f"cat <<'E'\n{status}E\n"), 1)
        # An engine that cannot answer is not clean.
        self.assertEqual(self.bans("echo boom >&2; exit 1\n", f"cat <<'E'\n{status}E\n"), 2)
        self.assertEqual(self.bans("echo null\n", "exit 255\n"), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
