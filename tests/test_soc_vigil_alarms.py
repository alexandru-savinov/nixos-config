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
import shutil
import stat
import tempfile
import time
import unittest
from unittest import mock

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


def kernel_proctitle(*argv):
    # What kernel/auditsc.c logs: the first MAX_PROCTITLE_AUDIT_LEN (128)
    # bytes of argv, trailing non-printables trimmed (audit_proctitle_rtrim).
    raw = "\x00".join(argv).encode()[:128].rstrip(b"\x00")
    return raw.hex().upper()


def event(serial, *, key, auid, exe, comm, path, argv, success="yes", syscall=257, enriched=True,
          uid="0", flags="0", title=None):
    stamp = f"msg=audit(1762790400.{serial % 1000:03d}:{serial})"
    # The kernel prints a key quoted, as (null), or hex when it holds several
    # keys joined by SOH. Uppercase-hex fixtures are passed through as-is.
    raw_key = key == "(null)" or all(c in "0123456789ABCDEF" for c in key)
    keyf = key if raw_key else f'"{key}"'
    sysc = (
        f"type=SYSCALL {stamp}: arch=c000003e syscall={syscall} success={success} exit=3 "
        f"a0=ffffff9c a1=55d0c2 a2={flags} a3=0 items=1 ppid=2201 pid={3000 + serial} auid={auid} "
        f"uid={uid} gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts0 ses=4 "
        f'comm="{comm}" exe="{exe}" subj=unconfined key={keyf}'
    )
    if enriched:
        sysc += '\x1dARCH=x86_64 SYSCALL=openat AUID="alex" UID="root" GID="root"'
    return "\n".join([
        sysc,
        f'type=CWD {stamp}: cwd="/root"',
        f'type=PATH {stamp}: item=0 name="{path}" inode=1234 dev=00:1a mode=0100400 '
        f"ouid=0 ogid=0 rdev=00:00 nametype=NORMAL cap_fp=0 cap_fi=0 cap_fe=0 cap_fver=0 cap_frootid=0",
        f"type=PROCTITLE {stamp}: proctitle={title or hexargv(*argv)}",
    ])


def login_reads_agenix(serial=1, auid="1000", success="yes"):
    return event(serial, key="agenix-secrets", auid=auid, exe=CAT, comm="cat",
                 path="/run/agenix.d/3/example-one", success=success,
                 argv=["cat", "/run/agenix/example-one"])


def service_reads_agenix(serial=2):
    return event(serial, key="agenix-secrets", auid=UNSET, exe=AGE, comm="rage",
                 path="/run/agenix.d/3/example-two", argv=[AGE, "--decrypt"])


PERL_ENV = f"/nix/store/{'e' * 32}-perl-5.40.0-env/bin/perl"
STORE_ETC = f"/nix/store/{'c' * 32}-etc/etc"


def activation_writes_sudoers(serial=3, auid="1000", setup_etc=SETUP_ETC, exe=PERL, argv=None,
                              path="/etc/sudoers", truncated=False):
    argv = argv or [PERL_ENV, setup_etc, STORE_ETC]
    return event(serial, key="sudoers", auid=auid, exe=exe, comm="perl",
                 path=path, syscall=82, argv=argv,
                 title=kernel_proctitle(*argv) if truncated else None)


def classify(*events):
    return sva.audit_hits("\n----\n".join(events) + "\n")


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

    def test_activation_touching_another_path_fires(self):
        self.assertEqual(len(classify(activation_writes_sudoers(path="/etc/sudoers.d/x"))), 1)

    def test_activation_tmp_then_rename_fires(self):
        self.assertEqual(len(classify(activation_writes_sudoers(path="/etc/sudoers.tmp"))), 1)

    def test_activation_with_foreign_setup_etc_fires(self):
        # Same perl, a setup-etc.pl that is not this generation's: not exempt.
        self.assertEqual(len(classify(activation_writes_sudoers(setup_etc=OTHER_SETUP_ETC))), 1)

    def test_setup_etc_as_a_mere_argument_fires(self):
        # The pinned path present in argv but not what perl runs: not exempt.
        for argv in ([PERL_ENV, "-e", "1", SETUP_ETC],
                     [PERL_ENV, "-e", "1", SETUP_ETC, STORE_ETC],
                     [PERL_ENV, STORE_ETC, SETUP_ETC],
                     [PERL_ENV, SETUP_ETC]):
            self.assertEqual(len(classify(activation_writes_sudoers(argv=argv))), 1, argv)

    def test_setup_etc_with_a_non_store_etc_tree_fires(self):
        for tree in ("/tmp/evil-etc", STORE_ETC + "/..", f"/nix/store/{'c' * 32}-etc/etc/x"):
            self.assertEqual(len(classify(activation_writes_sudoers(argv=[PERL_ENV, SETUP_ETC, tree]))), 1, tree)

    def test_truncated_activation_with_foreign_script_fires(self):
        for argv in ([PERL_ENV, OTHER_SETUP_ETC, STORE_ETC],
                     [PERL_ENV, "-e", "1", SETUP_ETC, STORE_ETC],
                     [PERL_ENV + "x" * 60, SETUP_ETC, STORE_ETC]):  # cut inside the script word
            self.assertEqual(len(classify(activation_writes_sudoers(argv=argv, truncated=True))), 1, argv)

    def test_truncated_activation_with_a_non_store_tree_fires(self):
        # Cut at 128 leaves "/t" of /tmp/...: not a prefix of the store shape.
        self.assertEqual(len(classify(activation_writes_sudoers(
            argv=[PERL_ENV, SETUP_ETC, "/tmp/evil-etc"], truncated=True))), 1)

    def test_short_two_word_title_is_not_a_cut(self):
        # Two words well under the limit: the third was never there.
        self.assertEqual(len(classify(activation_writes_sudoers(argv=[PERL_ENV, SETUP_ETC], truncated=True))), 1)

    def test_activation_args_from_non_store_perl_fires(self):
        self.assertEqual(len(classify(activation_writes_sudoers(exe="/tmp/perl"))), 1)

    def test_activation_shape_does_not_cover_agenix(self):
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
                  path="/run/agenix.d/3/a", argv=["cat"], enriched=False))), 1)

    def test_missing_auid_fires(self):
        ev = login_reads_agenix().replace(" auid=1000 ", " ", 1)
        self.assertEqual(len(classify(ev)), 1)

    # ── negative arms ──
    def test_service_read_of_agenix_is_silent(self):
        self.assertEqual(classify(service_reads_agenix()), [])

    def test_login_activation_write_to_sudoers_fires(self):
        # Was: exempt as the activation's /etc writer. Rule 3 is removed.
        hits = classify(activation_writes_sudoers())
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["keys"], ["sudoers"])

    def test_activation_with_login_auid_fires_for_any_argv(self):
        for argv, trunc in (([PERL_ENV, SETUP_ETC, STORE_ETC], False), ([PERL_ENV, SETUP_ETC, STORE_ETC], True),
                            ([PERL_ENV, "-e", "1"], False)):
            self.assertEqual(len(classify(activation_writes_sudoers(argv=argv, truncated=trunc))), 1, argv)

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
        self.assertEqual(len(sva.audit_hits(ev)), 1)

    def test_unparseable_line_fails_closed(self):
        with self.assertRaises(ValueError):
            sva.audit_hits("event: something audit 4.2 might print\n")
        with self.assertRaises(ValueError):
            classify(service_reads_agenix(), "typ=SYSCALL msg=audit(1.0:1): key=\"sudoers\"")

    def test_empty_and_noise_are_silent(self):
        self.assertEqual(sva.audit_hits(""), [])
        self.assertEqual(sva.audit_hits("<no matches>\n----\n"), [])

    # ── record shape: a malformed event is an error, not a quiet one ──
    def scan_bad(self, text):
        return sva.audit_scan(text)[1]

    def test_syscall_missing_required_fields_is_bad(self):
        import re
        for field in ("arch", "syscall", "success", "exe", "key"):
            ev = re.sub(rf" {field}=(\"[^\"]*\"|\S+)", "", login_reads_agenix(), count=1)
            self.assertNotIn(f" {field}=", ev.split("\n")[0].split("\x1d")[0])
            self.assertEqual(len(self.scan_bad(ev)), 1, field)
            with self.assertRaises(ValueError):
                sva.audit_hits(ev)

    def test_null_path_name_on_a_watched_key_is_bad(self):
        for ev in (login_reads_agenix(), service_reads_agenix(),
                   event(60, key="sudoers", auid="1000", exe=CAT, comm="x", path="/etc/sudoers", argv=["x"])):
            for form in ("name=(null)", 'name="(null)"'):
                import re
                bad = re.sub(r'name="[^"]*"', form, ev, count=1)
                self.assertEqual(len(self.scan_bad(bad)), 1, (form, ev[:40]))
                with self.assertRaises(ValueError):
                    sva.audit_hits(bad)

    def test_null_path_name_on_an_unwatched_key_is_not_bad(self):
        ev = event(61, key="identity", auid="1000", exe=CAT, comm="x", path="/etc/passwd", argv=["x"])
        self.assertEqual(self.scan_bad(ev.replace('name="/etc/passwd"', "name=(null)")), [])

    def test_a_named_path_next_to_a_null_one_still_reports_the_null(self):
        ev = login_reads_agenix() + "\n" + (
            'type=PATH msg=audit(1762790400.001:1): item=1 name=(null) inode=1 dev=00:1a mode=0')
        self.assertEqual(len(self.scan_bad(ev)), 1)

    def test_parse_events_is_gone(self):
        self.assertFalse(hasattr(sva, "parse_events"))

    def test_unterminated_key_is_bad_never_zero_and_zero(self):
        import re
        for ev in (login_reads_agenix(), service_reads_agenix(),
                   event(62, key="identity", auid="1000", exe=CAT, comm="x", path="/etc/passwd", argv=["x"])):
            cut = re.sub(r'key="([^"]*)"', r'key="\1', ev, count=1)
            self.assertNotEqual(cut, ev)
            self.assertEqual(len(self.scan_bad(cut)), 1, ev[:30])
            with self.assertRaises(ValueError):
                sva.audit_hits(cut)

    def test_watched_path_missing_name_or_item_is_bad(self):
        import re
        for field in ("name", "item"):
            ev = re.sub(rf" {field}=(\"[^\"]*\"|\S+)", "", login_reads_agenix(), count=1)
            self.assertGreaterEqual(len(self.scan_bad(ev)), 1, field)
        # Not a watched key: not this rule's business.
        ev = event(63, key="identity", auid="1000", exe=CAT, comm="x", path="/etc/passwd", argv=["x"])
        self.assertEqual(self.scan_bad(re.sub(r" name=\"[^\"]*\"", "", ev, count=1)), [])

    def test_fewer_path_records_than_items_is_bad(self):
        two = login_reads_agenix().replace(" items=1 ", " items=2 ", 1)
        self.assertEqual(len(self.scan_bad(two)), 1)
        extra = two.replace("type=PROCTITLE", "type=PATH msg=audit(1762790400.001:1): item=1 name=\"/run/agenix.d/3\" inode=1 dev=00:1a mode=040755\ntype=PROCTITLE", 1)
        self.assertEqual(self.scan_bad(extra), [])
        self.assertEqual(len(sva.audit_hits(extra)), 1)

    def test_missing_or_garbled_items_on_a_watched_event_is_bad(self):
        import re
        for ev in (re.sub(r" items=\d+", "", login_reads_agenix(), count=1),
                   login_reads_agenix().replace(" items=1 ", " items=x ", 1)):
            self.assertEqual(len(self.scan_bad(ev)), 1)

    def test_path_without_a_syscall_in_the_event_is_bad(self):
        lines = login_reads_agenix().split("\n")
        orphan = "\n".join(l for l in lines if not l.startswith("type=SYSCALL"))
        self.assertEqual(len(self.scan_bad(orphan)), 1)

    def test_well_formed_events_are_not_bad(self):
        for ev in (login_reads_agenix(), service_reads_agenix(),
                   activation_writes_sudoers(), login_reads_agenix().replace(" auid=1000 ", " ", 1)):
            self.assertEqual(self.scan_bad(ev), [])

    def test_events_without_path_or_syscall_are_not_bad(self):
        login = "type=USER_LOGIN msg=audit(1762790400.001:50): pid=1 uid=0 auid=1000 msg='op=login'"
        self.assertEqual(self.scan_bad(login), [])

    # ── mixed batch: only the login event survives ──
    def test_mixed_batch(self):
        # The login-attributed activation write is a hit too (rule 3 removed);
        # before, only serial 13 survived.
        hits = classify(service_reads_agenix(11), activation_writes_sudoers(12),
                        login_reads_agenix(13), service_reads_agenix(14))
        self.assertEqual([h["serial"] for h in hits], ["12", "13"])


# ── the council's key read is an ordinary agenix read ──
# A read of jev-openrouter-key by the council user's node process used to be
# exempt (rule 4). The exemption is removed: it is a login reading a secret.
NODE = f"/nix/store/{'n' * 32}-nodejs-22.22.0/bin/node"
COUNCIL_UID = "993"
O_RDONLY_CLOEXEC = "80000"  # what node's readFileSync passes to openat


def council_read(serial=40, *, auid=COUNCIL_UID, uid=COUNCIL_UID, exe=NODE,
                 path="/run/agenix/jev-openrouter-key", flags=O_RDONLY_CLOEXEC, syscall=257):
    return event(serial, key="agenix-secrets", auid=auid, uid=uid, exe=exe, comm="node",
                 path=path, flags=flags, syscall=syscall,
                 argv=["node", "/var/lib/sancta/.claude/skills/council/scripts/jev-shadow.mjs"])


def council_hits(*events):
    return classify(*events)


ALEX = "1000"
ADMINS = {"alexandru": ALEX, "agent": "1001"}


def root_exec(serial, auid, key="root-exec", argv=("sudo", "-n", "id")):
    """What the root-exec rule logs: execve with euid 0 under a login's auid.
    Hand-built like the other fixtures, not captured from choir."""
    stamp = f"msg=audit(1762790500.{serial % 1000:03d}:{serial})"
    # Several keys arrive hex-encoded and unquoted, as in event() above.
    keyf = key if key == "(null)" or all(c in "0123456789ABCDEF" for c in key) else f'"{key}"'
    return "\n".join([
        f"type=SYSCALL {stamp}: arch=c000003e syscall=59 success=yes exit=0 a0=55d0c2 a1=55d0d2 "
        f"a2=55d0e2 a3=7ffd items=2 ppid=2201 pid={4000 + serial} auid={auid} uid=0 gid=0 euid=0 "
        f'suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts0 ses=4 comm="id" exe="{ID}" '
        f"subj=unconfined key={keyf}",
        f'type=EXECVE {stamp}: argc=1 a0="id"',
        f"type=PROCTITLE {stamp}: proctitle={hexargv(*argv)}",
    ])


ID = f"/nix/store/{H}-coreutils-9.8/bin/id"
SSHD = f"/nix/store/{'s' * 32}-openssh-10.0p1/bin/sshd"


def pam_record(serial, rtype, *, res="success", acct=None, ident=None, auid=ALEX, extra=""):
    stamp = f"msg=audit(1762790600.{serial % 1000:03d}:{serial})"
    who = f'acct="{acct}" ' if acct else ""
    idf = f"id={ident} " if ident else ""
    return (f"type={rtype} {stamp}: pid={5000 + serial} uid=0 auid={auid} ses=3 "
            f"subj=unconfined msg='op=login {idf}{who}exe=\"{SSHD}\" hostname=? "
            f"addr=100.64.0.7 terminal=ssh res={res}'\x1dUID=\"root\" AUID=\"alexandru\"{extra}")


class NamedAccountRule(unittest.TestCase):
    def hits(self, *events, admins=ADMINS):
        return sva.audit_hits("\n----\n".join(events) + "\n", admins)

    # ── root-exec ──
    def test_root_exec_by_named_account_fires(self):
        hits = self.hits(root_exec(10, ALEX))
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["kind"], "admin-root-exec")
        self.assertEqual(hits[0]["account"], "alexandru")
        self.assertEqual(hits[0]["exe"], ID)
        self.assertEqual(hits[0]["comm"], "id")
        self.assertEqual(hits[0]["proctitle"], "sudo -n id")

    def test_root_exec_by_other_uid_is_not_a_hit(self):
        self.assertEqual(self.hits(root_exec(11, "993")), [])

    def test_root_exec_with_unset_auid_is_not_a_hit(self):
        self.assertEqual(self.hits(root_exec(12, UNSET)), [])

    def test_other_key_by_named_uid_is_not_a_root_exec_hit(self):
        self.assertEqual(self.hits(root_exec(13, ALEX, key="other")), [])

    def test_multi_key_event_with_root_exec_fires(self):
        keys = "\x01".join(["other", "root-exec"]).encode().hex().upper()
        hits = self.hits(root_exec(14, ALEX, key=keys))
        self.assertEqual([h.get("kind") for h in hits], ["admin-root-exec"])

    # ── sessions ──
    def test_successful_login_by_acct_fires(self):
        hits = self.hits(pam_record(20, "USER_LOGIN", acct="alexandru"))
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["kind"], "admin-session")
        self.assertEqual(hits[0]["account"], "alexandru")
        self.assertEqual(hits[0]["addr"], "100.64.0.7")
        self.assertEqual(hits[0]["terminal"], "ssh")

    def test_successful_login_by_id_fires(self):
        # sshd's success form: id=<uid>, no acct=.
        self.assertEqual(len(self.hits(pam_record(21, "USER_LOGIN", ident="1001", auid="1001"))), 1)

    def test_user_start_fires_and_agent_counts(self):
        hits = self.hits(pam_record(22, "USER_START", acct="agent", auid="1001"))
        self.assertEqual([(h["kind"], h["account"]) for h in hits], [("admin-session", "agent")])

    def test_failed_login_is_not_a_hit(self):
        self.assertEqual(self.hits(pam_record(23, "USER_LOGIN", acct="alexandru", res="failed")), [])

    def test_login_by_other_account_is_not_a_hit(self):
        self.assertEqual(self.hits(pam_record(24, "USER_LOGIN", acct="www-data", auid="33")), [])

    def test_sudo_session_for_root_is_not_a_session_hit(self):
        self.assertEqual(self.hits(pam_record(25, "USER_START", acct="root", auid=ALEX)), [])

    def test_other_pam_types_are_ignored(self):
        self.assertEqual(self.hits(pam_record(26, "USER_AUTH", acct="alexandru")), [])

    def test_session_record_without_res_is_malformed(self):
        rec = pam_record(27, "USER_LOGIN", acct="alexandru").replace(" res=success", "")
        with self.assertRaises(ValueError):
            self.hits(rec)

    def test_empty_account_map_is_inert(self):
        evs = (root_exec(30, ALEX), pam_record(31, "USER_LOGIN", acct="alexandru"))
        self.assertEqual(self.hits(*evs, admins={}), [])
        self.assertEqual(sva.audit_hits("\n----\n".join(evs) + "\n"), [])

    def test_failed_login_logs_a_notice(self):
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.hits(pam_record(32, "USER_LOGIN", acct="alexandru", res="failed"))
        self.assertIn("NOTICE audit", out.getvalue())
        self.assertIn("alexandru", out.getvalue())


class CouncilKeyRead(unittest.TestCase):
    # Intentional behaviour change: these were the silent arms of rule 4.
    def test_council_key_read_via_symlinked_path_fires(self):
        hits = council_hits(council_read())
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]["paths"], ["/run/agenix/jev-openrouter-key"])

    def test_council_key_read_via_resolved_generation_path_fires(self):
        self.assertEqual(len(council_hits(council_read(path="/run/agenix.d/2/jev-openrouter-key"))), 1)

    def test_same_uid_reading_another_secret_fires(self):
        for p in ("/run/agenix/openrouter-api-key", "/run/agenix.d/2/anthropic-api-key",
                  "/run/agenix/jev-openrouter-key.bak", "/run/agenix.d/2/x/jev-openrouter-key"):
            self.assertEqual(len(council_hits(council_read(path=p))), 1, p)

    def test_cat_reading_the_council_key_fires(self):
        self.assertEqual(len(council_hits(council_read(exe=CAT))), 1)

    def test_non_store_node_reading_the_council_key_fires(self):
        self.assertEqual(len(council_hits(council_read(exe="/tmp/nodejs-22/bin/node"))), 1)

    def test_other_auid_reading_the_council_key_fires(self):
        for auid in ("1000", "0"):
            self.assertEqual(len(council_hits(council_read(auid=auid))), 1, auid)

    def test_council_auid_with_root_uid_fires(self):
        self.assertEqual(len(council_hits(council_read(uid="0"))), 1)

    def test_write_open_of_the_council_key_fires(self):
        for flags in ("80001", "80002", "80241"):
            self.assertEqual(len(council_hits(council_read(flags=flags))), 1, flags)

    def test_non_openat_syscall_fires(self):
        self.assertEqual(len(council_hits(council_read(syscall=90))), 1)

    def test_relative_path_fires(self):
        self.assertEqual(len(council_hits(council_read(path="jev-openrouter-key"))), 1)

    def test_mixed_batch_keeps_every_login_read(self):
        hits = council_hits(council_read(41), council_read(42, exe=CAT), service_reads_agenix(43))
        self.assertEqual([h["serial"] for h in hits], ["41", "42"])

    def test_service_read_of_the_council_key_stays_silent(self):
        # Rule 2 is unchanged: an unset auid is still ignored.
        self.assertEqual(council_hits(council_read(auid=UNSET)), [])


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

    def test_crowdsec_empty_list_means_none(self):
        self.assertEqual(sva.home_bans("[]", f2b(), NEVER_BAN), [])
        self.assertEqual(sva.home_bans(" []\n", f2b(), NEVER_BAN), [])

    def test_empty_cscli_output_is_unreadable(self):
        for text in ("", "\n", "  "):
            with self.assertRaises(ValueError, msg=repr(text)):
                sva.home_bans(text, f2b(), NEVER_BAN)

    def test_entries_without_the_expected_fields_are_unreadable(self):
        for text in ("[{}]", '[{"id": 1}]', '[{"decisions": [{}]}]',
                     '[{"decisions": [{"scope": "Ip"}]}]',
                     '[{"decisions": [{"value": "100.64.1.1"}]}]',
                     '[{"decisions": "x"}]', '[{"decisions": null}]', '["x"]', "[null]", "[[]]"):
            with self.assertRaises(ValueError, msg=text):
                sva.home_bans(text, f2b(), NEVER_BAN)

    def test_null_nonstring_or_empty_scope_or_value_is_unreadable(self):
        for scope, value in ((None, "100.64.1.1"), ("Ip", None), (1, "100.64.1.1"), ("Ip", 5),
                             ("", "100.64.1.1"), ("Ip", ""), ("  ", "x"), ("Ip", "  "),
                             (["Ip"], "x"), ("Country", None), (None, None)):
            text = json.dumps([{"decisions": [{"scope": scope, "value": value}]}])
            with self.assertRaises(ValueError, msg=text):
                sva.home_bans(text, f2b(), NEVER_BAN)

    def test_scans_classify_every_readable_entry_and_report_the_rest(self):
        nets = sva._networks(NEVER_BAN)
        text = json.dumps([{"decisions": [{"scope": "Ip", "value": "100.64.1.1", "type": "ban"}]}, {}, "x"])
        hits, errors = sva.crowdsec_scan(text, nets)
        self.assertEqual([h["value"] for h in hits], ["100.64.1.1"])
        self.assertEqual(len(errors), 2)
        hits, errors = sva.fail2ban_scan(f2b("192.168.1.20", "not-an-ip"), nets)
        self.assertEqual([h["value"] for h in hits], ["192.168.1.20"])
        self.assertEqual(len(errors), 1)

    def test_non_ip_scope_with_a_string_value_is_still_ignored(self):
        self.assertEqual(sva.home_bans(decisions(("Country", "RO"), ("AS", "AS123")), f2b(), NEVER_BAN), [])

    def test_empty_decision_list_inside_an_alert_is_fine(self):
        self.assertEqual(sva.home_bans('[{"id": 1, "decisions": []}]', f2b(), NEVER_BAN), [])

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


HEALTHY_RULES = (
    "-w /run/agenix -p rwa -k agenix-secrets\n"
    "-w /etc/sudoers -p wa -k sudoers\n"
    "-a always,exit -F arch=b64 -S execve -k root-exec\n"
)


def slurp(path):
    with open(path) as fh:
        return fh.read()


def fake(dirpath, name, body):
    path = os.path.join(dirpath, name)
    with open(path, "w") as fh:
        fh.write(f"#!{os.path.realpath(shutil.which('bash'))}\n" + body)
    os.chmod(path, stat.S_IRWXU)
    return path


STAMP_SCRIPT = os.environ.get(
    "SOC_STAMP_SCRIPT",
    os.path.join(HERE, "..", "modules", "services", "sancta-doctrine-guard-stamp.sh"),
)
BANS_STAMP_SCRIPT = os.environ.get(
    "SOC_BANS_STAMP_SCRIPT",
    os.path.join(HERE, "..", "modules", "services", "soc-bans-stamp.sh"),
)


def fake_touch(bindir):
    """A stand-in `touch` (BSD touch has no -d @N) that sets the mtime of its
    LAST argument. STAMP_TOUCH_FAIL = all | plain | epoch makes those calls
    fail (plain = `touch FILE`, epoch = `touch -d @N FILE`)."""
    py = os.path.realpath(__import__("sys").executable)
    fake(bindir, "touch", (
        'mode=plain; [ "$1" = -d ] && mode=epoch\n'
        'case "$STAMP_TOUCH_FAIL" in all) exit 1;; "$mode") exit 1;; esac\n'
        'for last; do :; done\n'
        'if [ "$mode" = epoch ]; then t=${2#@}; else t=$(date +%s); fi\n'
        f'exec {py} -c "import os,sys; open(sys.argv[2],\'a\').close(); os.utime(sys.argv[2],(int(sys.argv[1]),)*2)" "$t" "$last"\n'
    ))


def run_script(script, stamps, *, result="success", code="exited", status="0", fail="none", bindir=None):
    import shutil
    import subprocess
    # The fake bindir comes first (its `touch` wins); the inherited PATH
    # follows, because /usr/bin:/bin do not exist inside the Nix build sandbox.
    inherited = os.environ.get("PATH", "/usr/bin:/bin")
    bash = shutil.which("bash") or "/bin/bash"
    env = {"PATH": f"{bindir}:{inherited}", "STAMP_TOUCH_FAIL": fail,
           "SERVICE_RESULT": result, "EXIT_CODE": code, "EXIT_STATUS": status, **stamps}
    return subprocess.run([bash, script], env=env, capture_output=True, text=True).returncode


class Runners(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.sd = os.path.join(self.d, "state")
        os.mkdir(self.sd)
        self.cp = os.path.join(self.sd, "audit.checkpoint")
        self.last = os.path.join(self.sd, "audit.last-hit")
        self.log = os.path.join(self.d, "args")
        # Injected stand-ins for /run/current-system and /etc/sudoers.
        self.cs = os.path.join(self.d, "current-system")
        self.sudoers = os.path.join(self.d, "sudoers")
        self.last_system = os.path.join(self.sd, "audit.last-system")
        self.stamp = os.path.join(self.d, "stamp")
        self.health = os.path.join(self.d, "health")
        self.fbin = os.path.join(self.d, "fbin")
        os.mkdir(self.fbin)
        fake_touch(self.fbin)
        self.bootid = os.path.join(self.d, "boot_id")
        self.auditd_state = os.path.join(self.d, "auditd.state")
        self.chattr_calls = os.path.join(self.d, "chattr.calls")
        self.chattr = fake(self.d, "chattr", f'printf "%s\\n" "$@" >> "{self.chattr_calls}"\n')
        self.set_boot("boot-A")
        for gen in ("gen1", "gen2"):
            os.makedirs(os.path.join(self.d, gen, "etc"))
            with open(os.path.join(self.d, gen, "etc", "sudoers"), "w") as fh:
                fh.write("root ALL=(ALL) SETENV: ALL\n")
        self.switch("gen1")
        self.auditctl = self.make_auditctl()
        with open(self.sudoers, "w") as fh:
            fh.write("root ALL=(ALL) SETENV: ALL\n")

    def switch(self, gen):
        """Point the injected current-system at generation `gen`."""
        if os.path.lexists(self.cs):
            os.unlink(self.cs)
        os.symlink(os.path.join(self.d, gen), self.cs)

    def ausearch(self, script):
        return fake(self.d, "ausearch", f'echo "$@" >> {self.log}\n' + script)

    def stamp_like_execstoppost(self, rc):
        """What the unit's ExecStopPost does with the exit status."""
        with open(self.stamp, "a"):
            pass
        t = time.time() if rc == 0 else 1
        os.utime(self.stamp, (t, t))
        return rc

    def injected(self):
        return ["--current-system", self.cs, "--etc-sudoers", self.sudoers,
                "--auditctl", self.auditctl, "--auditd-state-file", self.auditd_state,
                "--chattr", self.chattr, "--stamp", self.stamp,
                "--expect-watch", "/run/agenix:rwa:agenix-secrets", "--expect-watch", "/etc/sudoers:wa:sudoers",
                "--boot-id-file", self.bootid, "--audit-log-dir", self.d,
                "--deploy-flag", os.path.join(self.d, "deploy-deadman-armed"),
                # Off by default so a small CI disk cannot fail unrelated tests.
                "--disk-warn-bytes", "0", "--disk-fail-bytes", "0", "--inode-fail-percent", "0"]

    def set_boot(self, ident):
        with open(self.bootid, "w") as fh:
            fh.write(ident + "\n")

    def make_auditctl(self, *, enabled=1, lost=0, pid=1, rules=None, status_exit=0, rules_exit=0,
                      suspended="no", dump_state=True):
        rules = HEALTHY_RULES if rules is None else rules
        state_report = (f'printf "writing to logs = yes\\nlogging suspended = {suspended}\\n" > "{self.auditd_state}"'
                        if dump_state else ":")
        return fake(self.d, "auditctl", (
            f'echo "$@" >> {self.log}.auditctl\n'
            'case "$1" in\n'
            f'  -s) [ {status_exit} -ne 0 ] && {{ echo boom >&2; exit {status_exit}; }}\n'
            f'      printf "enabled {enabled}\\nfailure 1\\npid {pid}\\nrate_limit 0\\nbacklog_limit 8192\\nlost {lost}\\nbacklog 0\\n";;\n'
            f'  -l) [ {rules_exit} -ne 0 ] && {{ echo boom >&2; exit {rules_exit}; }}\n'
            f"      cat <<'E'\n{rules}E\n;;\n"
            '  --signal) [ "$2" = state ] || exit 99\n'
            f'      {state_report};;\n'
            'esac\n'
        ))

    def audit(self, ausearch, hold=900, systemctl_exit=0, inactive=(), named=()):
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
        return self.stamp_like_execstoppost(
            sva.main(["audit", "--ausearch", ausearch, "--systemctl", systemctl,
                      "--require-active", "auditd.service", "--require-active", "audit-rules-nixos.service",
                      "--state-dir", self.sd, "--hold", str(hold)]
                      + [x for n in named for x in ("--named-account", n)] + self.injected()))

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
                                   "--state-dir", self.sd, "--hold", "900"] + self.injected()), 2)

    def test_missing_state_dir_is_error(self):
        a = self.ausearch(QUIET)
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        self.assertEqual(sva.main(["audit", "--ausearch", a, "--systemctl", systemctl,
                                   "--require-active", "auditd.service",
                                   "--state-dir", os.path.join(self.d, "nope"),
                                   "--hold", "900"] + self.injected()), 2)

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

    # ── a missing stamp, once a run has completed, reads red ──
    def test_missing_stamp_after_a_completed_run_is_an_error(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        os.unlink(self.stamp)
        os.unlink(self.log)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        self.assertFalse(os.path.exists(self.log), "evaluation must not run against a missing stamp")
        # The stamp script then wrote it invalid: red, not absent.
        self.assertEqual(int(os.stat(self.stamp).st_mtime), 1)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    # ── the stamp is written only by the stamp writer (ExecStopPost) ──
    def run_main_without_stamp_writer(self, ausearch):
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        return sva.main(["audit", "--ausearch", ausearch, "--systemctl", systemctl,
                         "--require-active", "auditd.service", "--state-dir", self.sd,
                         "--hold", "900"] + self.injected())

    def mtime(self):
        return int(os.stat(self.stamp).st_mtime)

    def test_the_stamp_stays_fresh_while_a_run_is_in_progress(self):
        # No pre-evaluation invalidation: a vigil read DURING a run (or two of
        # them) sees the previous clean result, never a transient red.
        with open(self.stamp, "w"):
            pass
        os.utime(self.stamp, None)
        before = self.mtime()
        seen = os.path.join(self.d, "stamp-during")
        py = os.path.realpath(__import__("sys").executable)
        a = self.ausearch(f'{py} -c "import os;open(\'{seen}\',\'a\').write(str(int(os.stat(\'{self.stamp}\').st_mtime))+\'\\\\n\')"\n'
                          f'{py} -c "import os;open(\'{seen}\',\'a\').write(str(int(os.stat(\'{self.stamp}\').st_mtime))+\'\\\\n\')"\nexit 1\n')
        self.assertEqual(self.run_main_without_stamp_writer(a), 0)
        self.assertEqual(slurp(seen).split(), [str(before), str(before)], "two reads mid-run, both the fresh mtime")
        self.assertEqual(self.mtime(), before, "the evaluator itself never writes the stamp")

    def test_the_evaluator_never_writes_either_stamp_in_any_outcome(self):
        for p in (self.stamp,):
            with open(p, "w"):
                pass
            os.utime(p, (12345, 12345))
        for ausearch in (self.ausearch(QUIET), self.ausearch("echo boom >&2\nexit 1\n"),
                         self.ausearch(self.fixture_cmd(login_reads_agenix() + "\n"))):
            self.run_main_without_stamp_writer(ausearch)
            self.assertEqual(self.mtime(), 12345)

    def test_stamp_scripts_use_no_shell_trap(self):
        for path in (STAMP_SCRIPT, BANS_STAMP_SCRIPT):
            with open(path) as fh:
                self.assertNotIn("trap ", fh.read(), path)

    def test_a_failed_freshening_never_advances_the_stamp(self):
        # touch and rm both blocked in the stamp writer after a clean run: the
        # script fails and does not claim success; the stamp keeps its old
        # mtime and ages out under the contract threshold (module-eval pins
        # the timing bound).
        import subprocess
        with open(self.stamp, "w"):
            pass
        os.utime(self.stamp, (12345, 12345))
        blocked = os.path.join(self.d, "blocked-bin")
        os.mkdir(blocked)
        for tool in ("touch", "rm"):
            fake(blocked, tool, "exit 1\n")
        import shutil
        env = {"PATH": blocked + ":" + os.environ.get("PATH", "/usr/bin:/bin"), "SANCTA_DOCTRINE_STAMP": self.stamp,
               "SERVICE_RESULT": "success", "EXIT_CODE": "exited", "EXIT_STATUS": "0"}
        bash = shutil.which("bash") or "/bin/bash"
        self.assertNotEqual(subprocess.run([bash, STAMP_SCRIPT], env=env, capture_output=True).returncode, 0)
        self.assertEqual(self.mtime(), 12345)

    def test_missing_stamp_on_the_first_run_is_not_an_error(self):
        self.assertFalse(os.path.exists(self.stamp))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_invalid_stamp_is_not_a_missing_stamp(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        os.utime(self.stamp, (1, 1))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_no_stamp_path_is_an_error(self):
        args = self.injected()
        args[args.index("--stamp") + 1] = ""
        a = self.ausearch(QUIET)
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        saved = os.environ.pop("SANCTA_DOCTRINE_STAMP", None)
        try:
            self.assertEqual(sva.main(["audit", "--ausearch", a, "--systemctl", systemctl,
                                       "--require-active", "auditd.service",
                                       "--state-dir", self.sd, "--hold", "900"] + args), 2)
        finally:
            if saved is not None:
                os.environ["SANCTA_DOCTRINE_STAMP"] = saved

    def test_bans_missing_stamp_after_a_completed_run_is_an_error(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        ok = (f"echo null\n", f"cat <<'E'\n{status}E\n")
        self.assertEqual(self.bans(*ok), 0)
        for victim in (self.stamp, self.health):
            os.unlink(victim)
            self.assertEqual(self.bans(*ok), 2, victim)
            self.assertEqual(self.bans(*ok), 0, victim)

    # ── bans: hits page, evaluator errors do not (two stamps) ──
    def stamps(self):
        return self.mtime_of(self.stamp), self.mtime_of(self.health)

    @staticmethod
    def mtime_of(path):
        return int(os.stat(path).st_mtime)

    def fresh(self, t):
        return abs(time.time() - t) < 60

    def test_clean_bans_run_freshens_both_stamps(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        self.assertEqual(self.bans("echo null\n", f"cat <<'E'\n{status}E\n"), 0)
        self.assertTrue(all(self.fresh(t) for t in self.stamps()))

    def test_a_ban_turns_only_the_bans_stamp_red(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        self.assertEqual(self.bans(f"cat <<'E'\n{decisions(('Ip', '100.64.1.1'))}\nE\n", f"cat <<'E'\n{status}E\n"), 1)
        bans, health = self.stamps()
        self.assertEqual(bans, 1)
        self.assertTrue(self.fresh(health))

    def test_evaluator_errors_turn_only_the_health_stamp_red(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        good_f2b = f"cat <<'E'\n{status}E\n"
        for cscli, f2b_body in (("exit 0\n", good_f2b),                       # empty cscli output
                                ("echo '[{}]'\n", good_f2b),                  # field-less entry
                                ('echo \'[{"decisions":[{"scope":null,"value":"x"}]}]\'\n', good_f2b),
                                ("echo null\n", "exit 255\n"),                # fail2ban unreadable
                                ("echo boom >&2; exit 1\n", good_f2b)):       # cscli failed
            self.assertEqual(self.bans(cscli, f2b_body), 2, cscli)
            bans, health = self.stamps()
            self.assertTrue(self.fresh(bans), f"an error must not page: {cscli}")
            self.assertEqual(health, 1, cscli)

    def test_a_hit_from_one_source_survives_an_error_in_the_other(self):
        # Both stamps go red: the ban pages, and the error is visible.
        status_ok = f2b("203.0.113.9").replace("\t", " ")
        status_hit = f2b("192.168.1.20").replace("\t", " ")
        cs_hit = f"cat <<'E'\n{decisions(('Ip', '100.64.1.1'))}\nE\n"
        for cscli, f2b_body, why in (
                (cs_hit, "exit 255\n", "crowdsec hit + failing fail2ban"),
                (cs_hit, "echo garbage\n", "crowdsec hit + unreadable fail2ban"),
                ("exit 1\n", f"cat <<'E'\n{status_hit}E\n", "fail2ban hit + failing cscli"),
                ("exit 0\n", f"cat <<'E'\n{status_hit}E\n", "fail2ban hit + empty cscli"),
                ("echo not-json\n", f"cat <<'E'\n{status_hit}E\n", "fail2ban hit + garbage cscli")):
            rc = self.bans(cscli, f2b_body)
            self.assertEqual(rc, 3, why)
            self.assertEqual(self.stamps(), (1, 1), why)

    def test_the_hit_is_logged_next_to_the_error(self):
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.bans(f"cat <<'E'\n{decisions(('Ip', '100.64.1.1'))}\nE\n", "exit 255\n")
        self.assertIn("ALARM ban", buf.getvalue())
        self.assertIn("EVALUATOR ERROR (bans)", buf.getvalue())

    def test_a_malformed_entry_does_not_hide_a_hit_beside_it(self):
        text = json.dumps([{"decisions": [{"scope": "Ip", "value": "100.64.1.1"}]}, {}])
        status_ok = f2b("203.0.113.9").replace("\t", " ")
        self.assertEqual(self.bans(f"cat <<'E'\n{text}\nE\n", f"cat <<'E'\n{status_ok}E\n"), 3)
        self.assertEqual(self.stamps(), (1, 1))

    def test_hits_from_both_sources_are_a_plain_hit(self):
        status_hit = f2b("192.168.1.20").replace("\t", " ")
        self.assertEqual(self.bans(f"cat <<'E'\n{decisions(('Ip', '100.64.1.1'))}\nE\n", f"cat <<'E'\n{status_hit}E\n"), 1)
        bans, health = self.stamps()
        self.assertEqual(bans, 1)
        self.assertTrue(self.fresh(health))

    def test_health_recovers_on_the_next_clean_run(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        ok = ("echo null\n", f"cat <<'E'\n{status}E\n")
        self.assertEqual(self.bans("exit 0\n", ok[1]), 2)
        self.assertEqual(self.bans(*ok), 0)
        self.assertTrue(all(self.fresh(t) for t in self.stamps()))

    def test_bans_evaluator_never_writes_either_stamp(self):
        for p in (self.stamp, self.health):
            with open(p, "w"):
                pass
            os.utime(p, (12345, 12345))
        status = f2b("203.0.113.9").replace("\t", " ")
        rc = sva.main(["bans", "--cscli", fake(self.d, "cscli", "echo null\n"),
                       "--fail2ban-client", fake(self.d, "f2b", f"cat <<'E'\n{status}E\n"),
                       "--cidrs", ",".join(NEVER_BAN), "--state-dir", self.sd,
                       "--stamp", self.stamp, "--health-stamp", self.health])
        self.assertEqual(rc, 0)
        self.assertEqual(self.stamps(), (12345, 12345), "only the stamp writer freshens them")

    # ── ausearch edge cases: each is an evaluator error ──
    def fixture_cmd(self, text):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(text)
        return f"cat {fixture}\n"

    def checkpoint(self, timestamp="100.123"):
        with open(self.cp, "w") as fh:
            fh.write(f"dev=0x1\ninode=123\noutput=- {timestamp}:99 0x514\n")

    def retained_log(self, timestamp="200.456", suffix=".1"):
        with open(os.path.join(self.d, "audit.log"), "a"):
            pass
        with open(os.path.join(self.d, "audit.log" + suffix), "w") as fh:
            fh.write(f"type=DAEMON_START msg=audit({timestamp}:1): auditd started\n")

    def recovery(self, status=12, first="", replay="", *, advances=True):
        advance = ('event=$(sed -n "s/.*msg=audit(\\([^)]*\\)).*/\\1/p" "$input/audit.log")\n'
                   'echo "output=- $event 0x4B0" > "$cp"\n') if advances else ""
        return self.ausearch(self.ADVANCE_PROLOGUE + f"""
if [ -z "$input" ]; then
    {first or ':'}
    exit {status}
fi
echo "NOTE - using logs in $input/audit.log" >&2
test ! -s "$input/audit.log" && exit 1
{advance}
{replay or ':'}
exit 0
""")

    def assert_reanchored(self, timestamp="200.456", suffix=".1"):
        file_id = sva.audit_file_id(os.path.join(self.d, "audit.log" + suffix))
        expected = sva.audit_checkpoint_text(file_id, f"output=- {timestamp}:1 0x4B0")
        self.assertEqual(slurp(self.cp), expected)

    def watchdog(self):
        return sva.main(["audit-watchdog", "--state-dir", self.sd, "--audit-log-dir", self.d])

    def test_status_12_appends_once_pages_and_recovers_without_ack(self):
        self.checkpoint()
        self.retained_log()
        marker = os.path.join(self.sd, "audit.checkpoint-mismatch")
        stamp = os.path.join(self.sd, "audit.coverage-gap")
        history = "existing F15 evidence\n"
        with open(stamp, "w") as fh:
            fh.write(history)
        original_inode = os.stat(stamp).st_ino
        rc, out = self.run_logged(self.recovery())
        self.assertEqual(rc, 0, out)
        self.assert_reanchored()
        entry = "from=100.123 to=200.456 cause=12\n"
        self.assertEqual(slurp(stamp), history + entry)
        self.assertEqual(os.stat(stamp).st_ino, original_inode)
        self.assertTrue(os.path.isfile(marker))
        self.assertEqual(self.watchdog(), 0)
        gap_signal = os.path.join(self.sd, "audit-gap-clean")
        self.assertEqual(os.stat(gap_signal).st_mtime, 1)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(self.watchdog(), 0)
        self.assertEqual(os.stat(gap_signal).st_mtime, 1)
        self.assertEqual(slurp(stamp), history + entry)
        os.unlink(marker)  # operator acknowledgement
        self.assertEqual(self.watchdog(), 0)
        self.assertGreater(os.stat(gap_signal).st_mtime, 1)
        self.assertEqual(slurp(stamp), history + entry)

    def test_gap_retry_after_append_does_not_repeat_the_record_after_rotation(self):
        self.checkpoint()
        self.retained_log()
        stamp = os.path.join(self.sd, "audit.coverage-gap")
        self.assertEqual(self.audit(self.recovery(advances=False)), 2)
        self.assertEqual(slurp(stamp), "from=100.123 to=200.456 cause=12\n")
        self.retained_log("300.789")
        self.assertEqual(self.audit(self.recovery()), 0)
        self.assertEqual(slurp(stamp), "from=100.123 to=200.456 cause=12\n")
        self.checkpoint("250.123")
        self.assertEqual(self.audit(self.recovery()), 0)
        self.assertEqual(slurp(stamp), "from=100.123 to=200.456 cause=12\n"
                                      "from=250.123 to=300.789 cause=12\n")

    def test_status_12_with_unwritable_gap_evidence_does_not_reemit_alarms(self):
        self.checkpoint()
        original = slurp(self.cp)
        self.retained_log()
        gap = os.path.join(self.sd, "audit.coverage-gap")
        os.mkdir(gap)  # deterministic append failure, even when run as root
        hit = self.fixture_cmd(login_reads_agenix(42) + "\n")
        search = self.recovery(first=hit, replay=hit)
        attempts = [self.run_logged(search) for _ in range(3)]
        self.assertEqual([rc for rc, _ in attempts], [2, 2, 2])
        self.assertEqual(slurp(self.cp), original)
        self.assertTrue(all("could not record checkpoint status 12" in out for _, out in attempts))
        self.assertEqual([len(self.alarm_lines(out)) for _, out in attempts], [0, 0, 0])
        os.rmdir(gap)
        rc, out = self.run_logged(search)
        self.assertEqual(rc, 1, out)
        self.assertEqual([h["serial"] for h in self.alarm_lines(out)], ["42"])
        self.assert_reanchored()

    def test_killed_replay_resumes_from_last_classified_file_after_rotation(self):
        import subprocess
        import sys

        self.checkpoint()
        original_checkpoint = slurp(self.cp)
        cursor = os.path.join(self.sd, "audit.replay")
        def log_path(suffix):
            return os.path.join(self.d, "audit.log" + suffix)

        for suffix, serial in ((".2", 41), (".1", 42), ("", 43)):
            with open(log_path(suffix), "w") as fh:
                fh.write(login_reads_agenix(serial) + "\n")
        oldest_id = sva.audit_file_id(log_path(".2"))
        interrupted = os.path.join(self.d, "interrupted")
        search = self.ausearch(self.ADVANCE_PROLOGUE + f"""
test -n "$input" || exit 12
echo "NOTE - using logs in $input/audit.log" >&2
event=$(head -n 1 "$input/audit.log" | sed -n 's/.*msg=audit(\\([^)]*\\)).*/\\1/p')
cat "$input/audit.log"
printf 'output=- %s 0x514\\n' "$event" > "$cp"
case "$event" in
  *:42) if [ ! -e '{interrupted}' ]; then
    touch '{interrupted}'
    kill -KILL "$PPID"
  fi;;
esac
""")
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        argv = [sys.executable, SCRIPT, "audit", "--ausearch", search, "--systemctl", systemctl,
                "--require-active", "auditd.service", "--require-active", "audit-rules-nixos.service",
                "--state-dir", self.sd, "--hold", "900", *self.injected()]
        env = {**os.environ, "TMPDIR": self.d}
        killed = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(killed.returncode, -9, killed.stdout + killed.stderr)
        self.assertEqual([h["serial"] for h in self.alarm_lines(killed.stdout)], ["41"])
        self.assertEqual(json.loads(slurp(cursor))["through"], oldest_id)
        self.assertEqual(slurp(self.cp), original_checkpoint)
        self.assertTrue(os.path.isfile(self.last))
        self.assertFalse(os.path.exists(self.last_eval()))
        for index in range(2, -1, -1):
            os.rename(log_path(f".{index}" if index else ""), log_path(f".{index + 1}"))
        with open(log_path(""), "w") as fh:
            fh.write(login_reads_agenix(44) + "\n")

        resumed = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(resumed.returncode, 1, resumed.stdout + resumed.stderr)
        self.assertEqual([h["serial"] for h in self.alarm_lines(resumed.stdout)], ["42", "43", "44"])
        self.assertEqual(slurp(self.log).count("--input-logs"), 1)
        self.assertIn(":44 0x514", slurp(self.cp))
        self.assertTrue(os.path.isfile(self.last_eval()))
        self.assertFalse(os.path.exists(cursor))
        self.assertEqual(len(slurp(os.path.join(self.sd, "audit.coverage-gap")).splitlines()), 1)

    def test_replay_reassembles_event_across_rotated_logs(self):
        self.checkpoint()
        first, rest = login_reads_agenix(42).split("\n", 1)
        for suffix, text in ((".2", first), (".1", rest), ("", "")):
            with open(os.path.join(self.d, "audit.log" + suffix), "w") as fh:
                fh.write(text + "\n" if text else "")
        oldest_inode = os.stat(os.path.join(self.d, "audit.log.2")).st_ino
        search = self.ausearch(self.ADVANCE_PROLOGUE + f"""
test -n "$input" || exit 10
if [ ! -e "$input/audit.log.1" ]; then
    # The oldest file alone has no complete event.
    echo 'output=- 0.000:0 0x0' > "$cp"
    exit 1
fi
grep -Fxq 'inode={oldest_inode}' "$cp" || exit 99
if [ -e "$input/audit.log.2" ]; then
    # Re-reading the checkpoint event requires both halves, even though
    # ausearch used the second file's inode when it wrote the checkpoint.
    grep -q '^type=SYSCALL' "$input/audit.log.2" || exit 99
    grep -q '^type=PROCTITLE' "$input/audit.log.1" || exit 99
    exit 1
fi
cat "$input/audit.log.1" "$input/audit.log"
echo 'output=- 1762790400.042:42 0x514' > "$cp"
""")
        rc, out = self.run_logged(search)
        self.assertEqual(rc, 1, out)
        hits = self.alarm_lines(out)
        self.assertEqual([h["serial"] for h in hits], ["42"])
        self.assertEqual(hits[0]["paths"], ["/run/agenix.d/3/example-one"])
        self.assertIn(f"inode={oldest_inode}\n", slurp(self.cp))

    def test_new_coverage_evidence_gets_append_only_protection(self):
        self.checkpoint()
        self.retained_log()
        path = os.path.join(self.sd, "audit.coverage-gap")
        self.assertEqual(self.audit(self.recovery()), 0)
        calls = slurp(self.chattr_calls).splitlines() if os.path.exists(self.chattr_calls) else []
        self.assertEqual(calls, ["+a", path])
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(slurp(path), "from=100.123 to=200.456 cause=12\n")

    def test_coverage_append_only_fallback_requires_an_unsupported_filesystem(self):
        self.checkpoint()
        self.retained_log()
        stamp = os.path.join(self.sd, "audit.coverage-gap")
        self.chattr = fake(self.d, "chattr", 'echo "$0: Operation not permitted while setting flags on $2" >&2\nexit 1\n')
        rc, out = self.run_logged(self.recovery())
        self.assertEqual(rc, 2, out)
        self.assertIn("chattr +a exited 1", out)
        self.assertEqual(slurp(stamp), "")
        self.chattr = fake(self.d, "chattr", 'echo "$0: Operation not supported while setting flags on $2" >&2\nexit 1\n')
        rc, out = self.run_logged(self.recovery())
        self.assertEqual(rc, 0, out)
        self.assertIn("filesystem does not support chattr +a", out)
        self.assertEqual(slurp(stamp), "from=100.123 to=200.456 cause=12\n")

    def test_short_gap_append_is_completed_without_overwriting_history(self):
        self.checkpoint()
        self.retained_log()
        stamp = os.path.join(self.sd, "audit.coverage-gap")
        append = os.write

        def short_write(fd, data):
            return append(fd, data[:7])

        with mock.patch.object(sva.os, "write", side_effect=short_write):
            self.assertEqual(self.audit(self.recovery()), 2)
        self.assertEqual(slurp(stamp), "from=10")
        self.assertEqual(self.audit(self.recovery()), 0)
        self.assertEqual(slurp(stamp), "from=100.123 to=200.456 cause=12\n")

    def test_replay_batch_boundary_preserves_complete_audit_events(self):
        self.checkpoint()
        self.retained_log()
        ordinary = "".join(
            f"type=DAEMON_START msg=audit(200.456:{i}): auditd started\n"
            for i in range(4095)
        )
        body = self.fixture_cmd(ordinary + login_reads_agenix() + "\n")
        rc, out = self.run_logged(self.recovery(replay=body))
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(self.alarm_lines(out)), 1)

    def test_coverage_stamp_io_is_append_only(self):
        import subprocess
        with open(SCRIPT) as fh:
            source = fh.read()
        # The path has a single reference and its writer only opens in append mode.
        refs = subprocess.run(["grep", "-nF", '"audit.coverage-gap"', SCRIPT],
                              check=True, text=True, capture_output=True).stdout.splitlines()
        self.assertEqual(len(refs), 1)
        self.assertIn('stamp = os.path.join(state, "audit.coverage-gap")', refs[0])
        writer = source.split("def record_coverage_gap(", 1)[1].split("\ndef ", 1)[0]
        grep = subprocess.run(["grep", "-En", r"unlink|truncate|remove|rename|O_TRUNC|replace\(|open\(stamp.*[\"']w"],
                              input=writer, text=True, capture_output=True)
        self.assertEqual(grep.returncode, 1, grep.stdout)
        self.assertIn("os.O_APPEND", writer)

    def test_checkpoint_status_10_and_11_replay_and_classify_hits(self):
        self.retained_log()
        for status in (10, 11):
            with self.subTest(status=status):
                if status == 10:
                    with open(self.cp, "w") as fh:
                        fh.write("corrupt\n")
                else:
                    self.checkpoint()
                body = self.fixture_cmd(login_reads_agenix() + "\n")
                rc, out = self.run_logged(self.recovery(status, replay=body))
                self.assertEqual(rc, 1, out)
                self.assertEqual(len(self.alarm_lines(out)), 1)
        self.assertEqual(slurp(os.path.join(self.sd, "audit.coverage-gap")),
                         "from=unknown to=200.456 cause=10\nfrom=100.123 to=200.456 cause=11\n")

    def test_mismatch_keeps_the_first_attempts_records_next_to_the_retrys(self):
        self.checkpoint()
        self.retained_log()
        first = self.fixture_cmd(login_reads_agenix(1) + "\n")
        second = os.path.join(self.d, "second")
        with open(second, "w") as fh:
            fh.write(login_reads_agenix(1) + "\n----\n" + login_reads_agenix(2) + "\n")
        rc, out = self.run_logged(self.recovery(11, first=first, replay=f"cat {second}"))
        self.assertEqual(rc, 1)
        self.assertEqual(sorted(h["serial"] for h in self.alarm_lines(out)), ["1", "2"])

    def test_mismatch_with_a_quiet_retry_still_alarms_on_the_first_attempt(self):
        self.checkpoint()
        self.retained_log()
        first = self.fixture_cmd(login_reads_agenix(5) + "\n")
        rc, out = self.run_logged(self.recovery(11, first=first))
        self.assertEqual(rc, 1)
        self.assertEqual([h["serial"] for h in self.alarm_lines(out)], ["5"])

    def test_watchdog_pages_on_stale_or_missing_success_and_short_retention(self):
        now = time.time()
        heartbeat = os.path.join(self.sd, "audit-clean")
        deadman = os.path.join(self.sd, "audit-deadman-clean")
        retention = os.path.join(self.sd, "audit-retention-clean")
        self.retained_log(f"{now - 47 * 3600:.3f}")
        self.retained_log(f"{now:.3f}", suffix="")
        self.assertEqual(self.watchdog(), 0)
        self.assertGreater(os.stat(deadman).st_mtime, 1)
        self.assertEqual(os.stat(retention).st_mtime, 1)
        first_check = os.path.join(self.sd, "audit-watchdog.started")
        os.utime(first_check, (now - 1801, now - 1801))
        self.assertEqual(self.watchdog(), 0)
        self.assertEqual(os.stat(deadman).st_mtime, 1)
        with open(heartbeat, "w"):
            pass
        self.retained_log(f"{now - 49 * 3600:.3f}", suffix=".2")
        self.assertEqual(self.watchdog(), 0)
        self.assertGreater(os.stat(deadman).st_mtime, 1)
        self.assertGreater(os.stat(retention).st_mtime, 1)
        os.utime(heartbeat, (now - 1801, now - 1801))
        self.assertEqual(self.watchdog(), 0)
        self.assertEqual(os.stat(deadman).st_mtime, 1)

    def test_watchdog_refreshes_all_healthy_stamps_left_by_a_previous_boot(self):
        now = time.time()
        self.retained_log(f"{now - 49 * 3600:.3f}")
        heartbeat = os.path.join(self.sd, "audit-clean")
        signals = [os.path.join(self.sd, f"audit-{name}-clean")
                   for name in ("deadman", "gap", "retention")]
        for stamp in [heartbeat, *signals]:
            with open(stamp, "w"):
                pass
            os.utime(stamp, (now - 20 * 60,) * 2)
        self.assertEqual(self.watchdog(), 0)
        self.assertTrue(all(os.stat(stamp).st_mtime > now - 1 for stamp in signals))
        self.assertLess(os.stat(heartbeat).st_mtime, now - 15 * 60)

    def test_audit_stamp_health_advances_on_hit_and_ages_on_evaluator_error(self):
        from unittest.mock import patch
        heartbeat = os.path.join(self.sd, "audit-clean")
        hits = os.path.join(self.sd, "audit-hits-clean")
        for code, status in (("exited", "1"), ("exited", "2"), ("killed", "9")):
            with patch.dict(os.environ, {"EXIT_CODE": code, "EXIT_STATUS": status,
                                         "SANCTA_DOCTRINE_STAMP": hits}):
                self.assertEqual(sva.main(["audit-stamp", "--state-dir", self.sd]), 0)
            self.assertEqual(os.stat(hits).st_mtime, 1)
            if status == "1":
                self.assertGreater(os.stat(heartbeat).st_mtime, 1)
                os.utime(heartbeat, (2345, 2345))
            else:
                self.assertEqual(os.stat(heartbeat).st_mtime, 2345)

    # ── evaluation boundary and coverage gap ──
    def last_eval(self):
        return os.path.join(self.sd, "audit.last-eval")

    def test_quiet_first_run_persists_a_boundary(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertFalse(os.path.exists(self.cp))
        self.assertLess(abs(time.time() - float(slurp(self.last_eval()))), 60)

    def test_gap_over_ten_minutes_is_an_error_with_a_journal_line(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        with open(self.last_eval(), "w") as fh:
            fh.write(f"{time.time() - 601:.0f}\n")
        rc, out = self.run_logged(self.ausearch(QUIET))
        self.assertEqual(rc, 2)
        self.assertIn("coverage gap", out)
        self.assertTrue(os.path.exists(self.last), "the hold starts so one red run is not absorbed")
        # The boundary moved on: the next run is not a gap, only the hold.
        self.assertEqual(self.audit(self.ausearch(QUIET)), 1)

    def test_gap_within_ten_minutes_is_fine(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        with open(self.last_eval(), "w") as fh:
            fh.write(f"{time.time() - 590:.0f}\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_gap_does_not_hide_a_hit_in_the_window(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        with open(self.last_eval(), "w") as fh:
            fh.write(f"{time.time() - 3600:.0f}\n")
        rc, out = self.run_logged(self.ausearch(self.fixture_cmd(login_reads_agenix() + "\n")))
        self.assertEqual(rc, 2)
        self.assertIn("ALARM audit", out)
        self.assertIn("coverage gap", out)

    def test_unreadable_boundary_is_a_gap(self):
        with open(self.last_eval(), "w") as fh:
            fh.write("garbage\n")
        rc, out = self.run_logged(self.ausearch(QUIET))
        self.assertEqual(rc, 2)
        self.assertIn("coverage gap", out)

    def test_exit_one_with_stdout_is_an_error(self):
        self.assertEqual(self.audit(self.ausearch("echo something\nexit 1\n")), 2)
        # ... and the events in it are still classified, window not consumed.
        with open(self.cp, "w") as fh:
            fh.write("old\n")
        body = self.fixture_cmd(login_reads_agenix() + "\n")
        rc, out = self.run_logged(self.ausearch(f"echo new > \"$(echo \"$@\" | sed 's/.*--checkpoint //')\"\n{body}exit 1\n"))
        self.assertEqual(rc, 2)
        self.assertIn("ALARM audit", out)
        self.assertEqual(slurp(self.cp), "old\n")

    def test_malformed_event_turns_the_runner_red(self):
        import re
        ev = re.sub(r" exe=\"[^\"]*\"", "", login_reads_agenix(), count=1)
        self.assertEqual(self.audit(self.ausearch(self.fixture_cmd(ev + "\n"))), 2)

    def test_exit_zero_with_stderr_is_an_error(self):
        self.assertEqual(self.audit(self.ausearch('echo "warning: x" >&2\nexit 0\n')), 2)
        self.assertEqual(self.audit(self.ausearch("exit 0\n")), 0)

    def test_missing_checkpoint_without_marker_is_a_first_run(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertIn("--start recent", slurp(self.log))
        # Quiet runs leave no checkpoint (ausearch writes one only with events),
        # so no marker yet and the next run is a first run again.
        self.assertFalse(os.path.exists(os.path.join(self.sd, "audit.installed")))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_marker_is_written_once_a_checkpoint_is_committed(self):
        marker = os.path.join(self.sd, "audit.installed")
        self.assertEqual(self.audit(self.advancing(service_reads_agenix() + "\n")), 0)
        self.assertTrue(os.path.exists(marker))

    def test_missing_checkpoint_with_marker_is_an_error(self):
        self.assertEqual(self.audit(self.advancing(service_reads_agenix() + "\n")), 0)
        os.unlink(self.cp)
        os.unlink(self.log)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        self.assertFalse(os.path.exists(self.log), "ausearch must not run as a first run")

    def test_present_checkpoint_with_marker_is_normal(self):
        self.assertEqual(self.audit(self.advancing(service_reads_agenix() + "\n")), 0)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertNotIn("--start recent", slurp(self.log).splitlines()[-1])

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

    def test_hit_next_to_garbage_line_is_not_lost(self):
        # The checkpoint has moved past this window, so the hit must be
        # logged and must start the hold even though the batch had a bad line.
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(login_reads_agenix() + "\ngarbage line\n")
        self.assertEqual(self.audit(self.ausearch(f"cat {fixture}\n")), 2)
        self.assertTrue(os.path.exists(self.last))
        hits, bad = sva.audit_scan(slurp(fixture))
        self.assertEqual((len(hits), len(bad)), (1, 1))
        # Next window is quiet: still red for the hold, not clean.
        self.assertEqual(self.audit(self.ausearch(QUIET)), 1)

    # ── the checkpoint moves only after the outcome is on disk ──
    # A fake ausearch that, like the real one, rewrites the file it was given
    # as --checkpoint when it finds events, and records what that file held.
    ADVANCE_PROLOGUE = (
        'cp=; input=; prev=\n'
        'for x in "$@"; do\n'
        '    case "$prev" in --checkpoint) cp=$x;; --input) input=$x;; esac\n'
        '    prev=$x\n'
        'done\n'
    )
    ADVANCING = ADVANCE_PROLOGUE + (
        '{ [ -e "$cp" ] && cat "$cp" || echo absent; } >> %(seen)s\n'
        'echo new > "$cp"\n'
        'cat %(fixture)s\n'
    )

    def advancing(self, text):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(text)
        return self.ausearch(self.ADVANCING % {"seen": os.path.join(self.d, "seen"), "fixture": fixture})

    def test_hit_is_not_lost_when_the_hold_cannot_be_recorded(self):
        with open(self.cp, "w") as fh:
            fh.write("old\n")
        a = self.advancing(login_reads_agenix() + "\n")
        os.mkdir(self.last)  # the hold file cannot be written
        self.assertEqual(self.audit(a), 2)
        # Not recorded => the window is still unread: checkpoint did not move.
        self.assertEqual(slurp(self.cp), "old\n")
        os.rmdir(self.last)
        # Next run sees the SAME window again and the hit lands.
        self.assertEqual(self.audit(a), 1)
        self.assertEqual(slurp(os.path.join(self.d, "seen")), "old\nold\n")
        self.assertTrue(os.path.isfile(self.last))
        self.assertEqual(slurp(self.cp), "new\n")

    def test_recorded_windows_advance_the_checkpoint(self):
        # The other arm: once the outcome is recorded the window is consumed,
        # for a hit, for routine events, and for a bad line (red, but moved on).
        for text, want in ((login_reads_agenix() + "\n", 1),
                           (service_reads_agenix() + "\n", 1),  # still in the hold
                           (login_reads_agenix() + "\ngarbage line\n", 2)):
            with open(self.cp, "w") as fh:
                fh.write("old\n")
            self.assertEqual(self.audit(self.advancing(text)), want)
            self.assertEqual(slurp(self.cp), "new\n")
            self.assertFalse(os.path.exists(self.cp + ".next"))

    def test_routine_window_advances_and_stays_clean(self):
        self.assertEqual(self.audit(self.advancing(service_reads_agenix() + "\n")), 0)
        self.assertEqual(slurp(self.cp), "new\n")
        self.assertFalse(os.path.exists(self.last))

    def test_quiet_window_leaves_the_checkpoint_alone(self):
        with open(self.cp, "w") as fh:
            fh.write("old\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(slurp(self.cp), "old\n")

    def test_stale_staged_checkpoint_is_never_used(self):
        # A run that died before its first commit leaves only the staged file.
        with open(self.cp + ".next", "w") as fh:
            fh.write("stale\n")
        self.assertEqual(self.audit(self.advancing(service_reads_agenix() + "\n")), 0)
        self.assertEqual(slurp(os.path.join(self.d, "seen")), "absent\n")
        self.assertIn("--start recent", slurp(self.log))

    def test_undecodable_byte_does_not_hide_the_hit(self):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "wb") as fh:
            fh.write(login_reads_agenix().encode() + b"\n\xff\xfe\n")
        self.assertEqual(self.audit(self.ausearch(f"cat {fixture}\n")), 2)
        self.assertTrue(os.path.isfile(self.last))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 1)

    def test_format_drift_turns_red(self):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write("unrecognised audit output\n")
        self.assertEqual(self.audit(self.ausearch(f"cat {fixture}\n")), 2)

    def test_routine_events_never_turn_red(self):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(service_reads_agenix() + "\n" + activation_writes_sudoers(auid=UNSET) + "\n")
        self.assertEqual(self.audit(self.ausearch(f"cat {fixture}\n")), 0)
        self.assertFalse(os.path.exists(self.last))

    # ── rule 3 is removed: a login-attributed sudoers write is always a hit;
    # a hash match against the current generation is journal context only ──
    def activation_fixture(self, **kw):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(activation_writes_sudoers(**kw) + "\n")
        return self.ausearch(f"cat {fixture}\n")

    def run_logged(self, a):
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = self.audit(a)
        return rc, buf.getvalue()

    def alarm_lines(self, out):
        return [json.loads(l.split("ALARM audit ", 1)[1]) for l in out.splitlines() if l.startswith("ALARM audit ")]

    def test_activation_write_matching_the_generation_is_still_a_hit(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.switch("gen2")  # live sudoers equals gen2's copy
        rc, out = self.run_logged(self.activation_fixture())
        self.assertEqual(rc, 1)
        self.assertNotIn("NOTICE", out)
        alarms = self.alarm_lines(out)
        self.assertEqual(len(alarms), 1)
        self.assertIs(alarms[0]["sudoers_matches_generation"], True)

    def test_hash_mismatch_is_a_hit_with_context(self):
        self.switch("gen2")
        with open(self.sudoers, "a") as fh:
            fh.write("extra ALL=(ALL) ALL\n")
        rc, out = self.run_logged(self.activation_fixture())
        self.assertEqual(rc, 1)
        self.assertIs(self.alarm_lines(out)[0]["sudoers_matches_generation"], False)

    def test_unchanged_generation_is_a_hit(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(self.audit(self.activation_fixture()), 1)

    def test_unreadable_context_does_not_hide_or_break_the_hit(self):
        os.unlink(self.sudoers)
        rc, out = self.run_logged(self.activation_fixture())
        self.assertEqual(rc, 1)
        self.assertIsNone(self.alarm_lines(out)[0]["sudoers_matches_generation"])

    def test_agenix_hit_carries_no_sudoers_context(self):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(login_reads_agenix() + "\n")
        rc, out = self.run_logged(self.ausearch(f"cat {fixture}\n"))
        self.assertNotIn("sudoers_matches_generation", self.alarm_lines(out)[0])

    def test_no_generation_state_is_kept(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertFalse(os.path.exists(self.last_system))

    # ── disk floor on the audit log filesystem (os.statvfs, injectable path) ──
    GIB = 1024 ** 3

    def audit_with_disk(self, free_gib, files=1000, favail=1000, warn=10, fail=5, inode_pct=5, statvfs_error=None):
        from unittest import mock
        import contextlib
        import io
        vfs = type("V", (), dict(f_bavail=int(free_gib * 1024), f_frsize=1024 ** 2, f_files=files, f_favail=favail))()
        args = [x for x in self.injected()]
        for flag, value in (("--disk-warn-bytes", warn * self.GIB), ("--disk-fail-bytes", fail * self.GIB),
                            ("--inode-fail-percent", inode_pct)):
            args[args.index(flag) + 1] = str(value)
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        buf = io.StringIO()
        patch = mock.patch("os.statvfs", side_effect=statvfs_error) if statvfs_error else mock.patch("os.statvfs", return_value=vfs)
        with patch, contextlib.redirect_stdout(buf):
            rc = self.stamp_like_execstoppost(sva.main(
                ["audit", "--ausearch", self.ausearch(QUIET), "--systemctl", systemctl,
                 "--require-active", "auditd.service", "--state-dir", self.sd, "--hold", "900"] + args))
        return rc, buf.getvalue()

    def test_disk_above_the_warn_threshold_is_clean_and_silent(self):
        rc, out = self.audit_with_disk(free_gib=50)
        self.assertEqual(rc, 0)
        self.assertNotIn("WARN", out)

    def test_disk_in_the_warn_band_logs_a_warn_and_stays_clean(self):
        rc, out = self.audit_with_disk(free_gib=7)
        self.assertEqual(rc, 0)
        self.assertIn("WARN audit", out)

    def test_disk_below_the_fail_floor_is_an_error(self):
        rc, out = self.audit_with_disk(free_gib=4)
        self.assertEqual(rc, 2)
        self.assertIn("nearly full", out)
        self.assertFalse(os.path.exists(self.log), "no quiet window is accepted on a full disk")

    def test_inodes_below_the_floor_are_an_error(self):
        rc, out = self.audit_with_disk(free_gib=50, files=1000, favail=40)
        self.assertEqual(rc, 2)
        self.assertIn("inodes", out)

    def test_inodes_at_the_floor_and_dynamic_inode_filesystems_are_fine(self):
        self.assertEqual(self.audit_with_disk(free_gib=50, files=1000, favail=50)[0], 0)
        self.assertEqual(self.audit_with_disk(free_gib=50, files=0, favail=0)[0], 0)

    def test_statvfs_error_is_an_error(self):
        rc, out = self.audit_with_disk(free_gib=50, statvfs_error=OSError("gone"))
        self.assertEqual(rc, 2)
        self.assertIn("cannot stat", out)

    def test_fail_floor_exactly_at_the_boundary_is_not_an_error(self):
        self.assertEqual(self.audit_with_disk(free_gib=5)[0], 0)

    # ── trail health: auditctl -s / -l, before a quiet window is accepted ──
    def test_trail_health_checked_before_a_quiet_window(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(slurp(self.log + ".auditctl").splitlines(), ["-s", "-l", "--signal state"])

    def test_suspended_auditd_stops_heartbeat_and_pages_even_with_free_disk(self):
        self.retained_log(f"{time.time() - 49 * 3600:.3f}", suffix="")
        heartbeat = os.path.join(self.sd, "audit-clean")
        deadman = os.path.join(self.sd, "audit-deadman-clean")

        def publish(rc):
            with mock.patch.dict(os.environ, {"EXIT_CODE": "exited", "EXIT_STATUS": str(rc),
                                             "SANCTA_DOCTRINE_STAMP": self.stamp}):
                self.assertEqual(sva.main(["audit-stamp", "--state-dir", self.sd]), 0)

        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        publish(0)
        before = os.stat(heartbeat).st_mtime_ns
        self.auditctl = self.make_auditctl(suspended="yes")
        rc, out = self.audit_with_disk(free_gib=50)
        publish(rc)
        self.assertEqual(rc, 2, out)
        self.assertIn("logging suspended", out)
        self.assertEqual(os.stat(heartbeat).st_mtime_ns, before)
        self.assertEqual(self.watchdog(), 0)
        self.assertEqual(os.stat(deadman).st_mtime, 1)
        rc, out = self.audit_with_disk(free_gib=4)
        self.assertEqual(rc, 2, out)
        self.assertIn("logging suspended", out)
        self.auditctl = self.make_auditctl()
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        publish(0)
        self.assertEqual(self.watchdog(), 0)
        self.assertGreater(os.stat(deadman).st_mtime, 1)

    def test_stale_healthy_auditd_report_is_an_evaluator_error(self):
        quiet = self.ausearch(QUIET)
        self.assertEqual(self.audit(quiet), 0)
        os.unlink(self.log)
        self.auditctl = self.make_auditctl(dump_state=False)
        with mock.patch.object(sva.time, "monotonic", side_effect=[0, 1, 6]):
            rc, out = self.run_logged(quiet)
        self.assertEqual(rc, 2, out)
        self.assertIn("did not write a fresh recording state", out)
        self.assertFalse(os.path.exists(self.log), "ausearch must not use a stale health report")

    def test_auditing_disabled_is_an_error(self):
        self.auditctl = self.make_auditctl(enabled=0)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        self.assertFalse(os.path.exists(self.log), "ausearch must not run on a blind trail")

    def test_enabled_one_and_two_are_healthy(self):
        for enabled in (1, 2):
            self.auditctl = self.make_auditctl(enabled=enabled)
            self.assertEqual(self.audit(self.ausearch(QUIET)), 0, enabled)

    def test_unparseable_status_is_an_error(self):
        self.auditctl = fake(self.d, "auditctl2", 'echo "something else"\n')
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)

    def test_auditctl_failure_is_an_error(self):
        for kw in ({"status_exit": 1}, {"rules_exit": 1}):
            self.auditctl = self.make_auditctl(**kw)
            self.assertEqual(self.audit(self.ausearch(QUIET)), 2, kw)

    def test_missing_watch_keys_are_an_error(self):
        for rules in ("-w /etc/sudoers -p wa -k sudoers\n",
                      "-w /run/agenix -p rwa -k agenix-secrets\n",
                      "No rules\n", "",
                      "-w /run/agenix -p rwa -k agenix-secrets-old\n-w /etc/sudoers -p wa -k sudoers\n"):
            self.auditctl = self.make_auditctl(rules=rules)
            self.assertEqual(self.audit(self.ausearch(QUIET)), 2, rules)

    def test_watch_keys_in_filter_form_are_accepted(self):
        self.auditctl = self.make_auditctl(rules=(
            "-a always,exit -F path=/etc/sudoers -F perm=wa -F key=sudoers\n"
            "-a always,exit -F dir=/run/agenix -F perm=rwa -F key=agenix-secrets\n"))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_first_run_stores_the_lost_counter_without_alarm(self):
        self.auditctl = self.make_auditctl(lost=7)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(slurp(os.path.join(self.sd, "audit.last-lost")).strip(), "boot-A 7")

    def test_unchanged_lost_counter_is_clean(self):
        self.auditctl = self.make_auditctl(lost=7)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_increased_lost_counter_is_an_error_and_holds_red(self):
        self.auditctl = self.make_auditctl(lost=7)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.auditctl = self.make_auditctl(lost=9)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        self.assertTrue(os.path.exists(self.last))
        self.assertEqual(slurp(os.path.join(self.sd, "audit.last-lost")).strip(), "boot-A 9")
        # A single blip must not read clean on the next quiet window ...
        self.assertEqual(self.audit(self.ausearch(QUIET)), 1)
        # ... and clears once the hold has elapsed.
        with open(self.last, "w") as fh:
            fh.write(f"{time.time() - 901:.0f}\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_kernel_loss_pages_after_the_hold_and_across_reboot_until_acknowledged(self):
        self.retained_log(f"{time.time() - 49 * 3600:.3f}", suffix="")
        signal = os.path.join(self.sd, "audit-gap-clean")
        quiet = self.ausearch(QUIET)
        self.assertEqual(self.audit(quiet), 0)
        self.assertEqual(self.watchdog(), 0)
        self.assertGreater(os.stat(signal).st_mtime, 1)
        self.auditctl = self.make_auditctl(lost=2)
        self.assertEqual(self.audit(quiet), 2)
        self.assertEqual(self.watchdog(), 0)
        self.assertEqual(os.stat(signal).st_mtime, 1)
        with open(self.last, "w") as fh:
            fh.write(f"{time.time() - 901:.0f}\n")
        self.set_boot("boot-B")
        self.auditctl = self.make_auditctl()
        self.assertEqual(self.audit(quiet), 0)
        self.assertEqual(self.watchdog(), 0)
        self.assertEqual(os.stat(signal).st_mtime, 1)
        os.unlink(os.path.join(self.sd, "audit.kernel-loss"))
        self.assertEqual(self.watchdog(), 0)
        self.assertGreater(os.stat(signal).st_mtime, 1)

    def test_a_loss_during_a_deploy_stays_red_and_is_annotated(self):
        # The deploy flag is context, never an exemption.
        flag = os.path.join(self.d, "deploy-deadman-armed")
        self.auditctl = self.make_auditctl(lost=7)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        with open(flag, "w"):
            pass
        self.auditctl = self.make_auditctl(lost=9)
        rc, out = self.run_logged(self.ausearch(QUIET))
        self.assertEqual(rc, 2)
        self.assertIn("lost 2 event(s)", out)
        self.assertIn("deploy in progress", out)
        self.assertTrue(os.path.exists(self.last), "the hold starts as for any loss")

    def test_a_loss_without_a_deploy_carries_no_deploy_note(self):
        self.auditctl = self.make_auditctl(lost=7)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.auditctl = self.make_auditctl(lost=9)
        rc, out = self.run_logged(self.ausearch(QUIET))
        self.assertEqual(rc, 2)
        self.assertNotIn("deploy in progress", out)

    def test_lost_counter_fall_within_one_boot_is_an_error(self):
        self.auditctl = self.make_auditctl(lost=9)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.auditctl = self.make_auditctl(lost=0)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        self.assertTrue(os.path.exists(self.last))
        self.assertEqual(slurp(os.path.join(self.sd, "audit.last-lost")).strip(), "boot-A 0")

    def test_new_boot_resets_the_lost_baseline(self):
        self.auditctl = self.make_auditctl(lost=9)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.set_boot("boot-B")
        self.auditctl = self.make_auditctl(lost=0)  # kernel counter restarted
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(slurp(os.path.join(self.sd, "audit.last-lost")).strip(), "boot-B 0")
        # ... and the new boot is then tracked like any other.
        self.auditctl = self.make_auditctl(lost=3)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)

    def test_a_high_counter_at_a_new_boot_is_not_an_increase(self):
        self.auditctl = self.make_auditctl(lost=1)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.set_boot("boot-B")
        self.auditctl = self.make_auditctl(lost=50)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_unreadable_boot_id_is_an_error(self):
        os.unlink(self.bootid)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)

    def test_legacy_counter_file_is_a_baseline_not_an_alarm(self):
        with open(os.path.join(self.sd, "audit.last-lost"), "w") as fh:
            fh.write("7\n")
        self.auditctl = self.make_auditctl(lost=2)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_auditd_pid_zero_is_an_error(self):
        self.auditctl = self.make_auditctl(pid=0)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        self.assertFalse(os.path.exists(self.log), "ausearch must not run on a blind trail")

    def test_rule_with_the_right_key_on_the_wrong_path_is_an_error(self):
        for rules in ("-w /run/agenix -p rwa -k agenix-secrets\n-w /etc/shadow -p wa -k sudoers\n",
                      "-w /tmp/agenix -p rwa -k agenix-secrets\n-w /etc/sudoers -p wa -k sudoers\n"):
            self.auditctl = self.make_auditctl(rules=rules)
            self.assertEqual(self.audit(self.ausearch(QUIET)), 2, rules)

    def test_rule_with_the_wrong_permission_is_an_error(self):
        for rules in ("-w /run/agenix -p r -k agenix-secrets\n-w /etc/sudoers -p wa -k sudoers\n",
                      "-w /run/agenix -p rwa -k agenix-secrets\n-w /etc/sudoers -p r -k sudoers\n"):
            self.auditctl = self.make_auditctl(rules=rules)
            self.assertEqual(self.audit(self.ausearch(QUIET)), 2, rules)

    def test_extra_filter_fields_on_an_otherwise_matching_rule_are_an_error(self):
        sudoers_ok = "-w /etc/sudoers -p wa -k sudoers\n"
        agenix_ok = "-w /run/agenix -p rwa -k agenix-secrets\n"
        for bad in ("-a always,exit -F path=/etc/sudoers -F perm=wa -F auid!=4294967295 -F key=sudoers\n",
                    "-a always,exit -F arch=b64 -S openat -F path=/etc/sudoers -F perm=wa -F key=sudoers\n",
                    "-a always,exit -F path=/etc/sudoers -F perm=wa -F uid=1000 -F key=sudoers\n",
                    "-w /etc/sudoers -p wa -k sudoers -k other\n",
                    "-w /etc/sudoers -p wa -F auid>=1000 -k sudoers\n",
                    "-a always,exit -F path=/etc/sudoers -F key=sudoers\n"):
            self.auditctl = self.make_auditctl(rules=agenix_ok + bad)
            self.assertEqual(self.audit(self.ausearch(QUIET)), 2, bad)
        # A narrowed rule next to the exact one does not make the exact one wrong.
        self.auditctl = self.make_auditctl(rules=agenix_ok + sudoers_ok + "-a always,exit -F path=/etc/sudoers -F perm=wa -F auid!=1 -F key=sudoers\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_extra_spaces_do_not_matter(self):
        self.auditctl = self.make_auditctl(rules="-w  /run/agenix   -p rwa -k agenix-secrets\n-w /etc/sudoers -p wa  -k sudoers\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_a_directory_watch_listed_with_a_trailing_slash_matches(self):
        # auditctl -l prints a watch that resolved to a directory as `-w DIR/`.
        self.auditctl = self.make_auditctl(rules="-w /run/agenix/ -p rwa -k agenix-secrets\n-w /etc/sudoers -p wa -k sudoers\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_a_different_path_is_still_an_error_after_slash_normalising(self):
        self.auditctl = self.make_auditctl(rules="-w /run/agenix.old/ -p rwa -k agenix-secrets\n-w /etc/sudoers -p wa -k sudoers\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)

    def test_permission_letters_in_any_order_match(self):
        self.auditctl = self.make_auditctl(rules="-w /run/agenix -p arw -k agenix-secrets\n-w /etc/sudoers -p aw -k sudoers\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_no_expected_watches_is_an_error(self):
        args = self.injected()
        i = args.index("--expect-watch")
        while "--expect-watch" in args:
            j = args.index("--expect-watch")
            del args[j:j + 2]
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        self.assertEqual(sva.main(["audit", "--ausearch", self.ausearch(QUIET), "--systemctl", systemctl,
                                   "--require-active", "auditd.service", "--state-dir", self.sd,
                                   "--hold", "900"] + args), 2)

    def test_expected_watches_come_from_the_arguments(self):
        # Another configuration (a different secrets mount) is judged by what it declares.
        self.auditctl = self.make_auditctl(rules="-w /run/agenix.d -p rwa -k agenix-secrets\n-w /etc/sudoers -p wa -k sudoers\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)

    def test_lost_events_do_not_hide_a_hit_in_the_window(self):
        self.auditctl = self.make_auditctl(lost=1)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.auditctl = self.make_auditctl(lost=2)
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(login_reads_agenix() + "\n")
        rc, out = self.run_logged(self.ausearch(f"cat {fixture}\n"))
        self.assertEqual(rc, 2)
        self.assertIn("ALARM audit", out)

    def bans(self, cscli_body, f2b_body):
        guard = 'case " $* " in *" --limit 0 "*) ;; *) echo "default limit 100" >&2; exit 3;; esac\n'
        rc = sva.main(["bans", "--cscli", fake(self.d, "cscli", guard + cscli_body),
                       "--fail2ban-client", fake(self.d, "f2b", f2b_body),
                       "--cidrs", ",".join(NEVER_BAN),
                       "--state-dir", self.sd, "--stamp", self.stamp, "--health-stamp", self.health])
        # What the unit's ExecStopPost (soc-bans-stamp.sh) does with the status.
        run_script(BANS_STAMP_SCRIPT, {"SANCTA_DOCTRINE_STAMP": self.stamp, "SOC_HEALTH_STAMP": self.health},
                   result="success" if rc == 0 else "exit-code", status=str(rc), bindir=self.fbin)
        return rc

    def test_bans_runner_arms(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        self.assertEqual(self.bans("echo null\n", f"cat <<'E'\n{status}E\n"), 0)
        self.assertEqual(self.bans(f"cat <<'E'\n{decisions(('Ip', '100.64.1.1'))}\nE\n",
                                   f"cat <<'E'\n{status}E\n"), 1)
        # An engine that cannot answer is not clean.
        self.assertEqual(self.bans("echo boom >&2; exit 1\n", f"cat <<'E'\n{status}E\n"), 2)
        self.assertEqual(self.bans("echo null\n", "exit 255\n"), 2)
        # An empty answer or an entry without fields is not "no decisions".
        self.assertEqual(self.bans("exit 0\n", f"cat <<'E'\n{status}E\n"), 2)
        self.assertEqual(self.bans("echo '[{}]'\n", f"cat <<'E'\n{status}E\n"), 2)
        self.assertEqual(self.bans("echo '[]'\n", f"cat <<'E'\n{status}E\n"), 0)


    # ── named accounts, end to end ──
    def passwd(self, table):
        def getpwnam(name):
            if name not in table:
                raise KeyError(name)
            return mock.Mock(pw_uid=table[name])
        return mock.patch.object(sva.pwd, "getpwnam", getpwnam)

    def test_named_account_session_is_an_alarm_and_red(self):
        a = self.ausearch(self.fixture_cmd(pam_record(40, "USER_LOGIN", acct="alexandru") + "\n"))
        with self.passwd({"alexandru": 1000}):
            self.assertEqual(self.audit(a, named=["alexandru"]), 1)

    def test_named_account_root_exec_is_an_alarm_and_red(self):
        a = self.ausearch(self.fixture_cmd(root_exec(41, ALEX) + "\n"))
        with self.passwd({"alexandru": 1000}):
            self.assertEqual(self.audit(a, named=["alexandru"]), 1)

    def test_unresolvable_named_account_is_an_evaluator_error(self):
        with self.passwd({}):
            self.assertEqual(self.audit(self.ausearch(QUIET), named=["alexandru"]), 2)
        self.assertFalse(os.path.exists(self.log), "ausearch must not run before the names resolve")

    def test_empty_named_accounts_leaves_the_rule_inert(self):
        a = self.ausearch(self.fixture_cmd(pam_record(42, "USER_LOGIN", acct="alexandru") + "\n"
                                           + root_exec(43, ALEX) + "\n"))
        with self.passwd({}):  # nothing may even be looked up
            self.assertEqual(self.audit(a), 0)

    def test_hit_is_logged_before_the_checkpoint_commits(self):
        # Same fail-closed order as every other hit: a failing ausearch next
        # to a session record leaves the window unconsumed.
        a = self.ausearch(self.fixture_cmd(pam_record(44, "USER_LOGIN", acct="alexandru") + "\n")
                          .rstrip("\n") + "\necho boom >&2\nexit 1\n")
        with self.passwd({"alexandru": 1000}):
            self.assertEqual(self.audit(a, named=["alexandru"]), 2)
        self.assertFalse(os.path.exists(self.cp))


class StampScript(unittest.TestCase):
    """modules/services/sancta-doctrine-guard-stamp.sh, run for real with a
    stand-in `touch` that can be made to fail (BSD touch has no -d @N)."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.bin = os.path.join(self.d, "bin")
        os.mkdir(self.bin)
        self.stamp = os.path.join(self.d, "stamp")
        fake_touch(self.bin)

    def run_stamp(self, *, result="success", code="exited", status="0", fail="none"):
        return run_script(STAMP_SCRIPT, {"SANCTA_DOCTRINE_STAMP": self.stamp}, result=result, code=code,
                          status=status, fail=fail, bindir=self.bin)

    def mtime(self):
        return int(os.stat(self.stamp).st_mtime)

    def green(self):
        with open(self.stamp, "w"):
            pass
        os.utime(self.stamp, None)

    def test_clean_run_stamps_now(self):
        self.assertEqual(self.run_stamp(), 0)
        self.assertLess(abs(time.time() - self.mtime()), 60)

    def test_failed_run_stamps_epoch_plus_one(self):
        self.green()
        self.assertEqual(self.run_stamp(result="exit-code", status="2"), 0)
        self.assertEqual(self.mtime(), 1)

    def test_every_non_success_result_invalidates_a_fresh_stamp(self):
        # ExecStopPost sees these after SIGKILL, OOM and timeouts too.
        for kw in (dict(result="exit-code", status="1"), dict(result="exit-code", status="2"),
                   dict(result="timeout", code="killed", status="TERM"), dict(result="signal", code="killed", status="KILL"),
                   dict(result="oom-kill", code="killed", status="KILL"), dict(result="core-dump", code="dumped", status="SEGV"),
                   dict(result="success", code="exited", status="3"), dict(result="", code="", status="")):
            self.green()
            self.assertEqual(self.run_stamp(**kw), 0, kw)
            self.assertEqual(self.mtime(), 1, kw)

    def test_failed_write_does_not_leave_the_old_stamp_green(self):
        self.green()
        self.assertNotEqual(self.run_stamp(fail="plain"), 0)
        self.assertEqual(self.mtime(), 1)

    def test_failed_write_and_failed_invalidation_remove_the_stamp(self):
        self.green()
        self.assertNotEqual(self.run_stamp(fail="all"), 0)
        self.assertFalse(os.path.exists(self.stamp))

    def test_failed_run_whose_invalidation_fails_removes_the_stamp(self):
        self.green()
        self.assertNotEqual(self.run_stamp(result="exit-code", status="2", fail="all"), 0)
        self.assertFalse(os.path.exists(self.stamp))


# Captured verbatim from sancta-choir (gen 57, 2026-11-22). Real kernel/auditctl
# output, not hand-built, so the comparison is tested against the true format.
CHOIR_AUDITCTL_L = """\
-w /run/agenix.d -p rwa -k agenix-secrets
-w /etc/sudoers -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd-config
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -F key=root-exec
-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -F key=root-exec
"""
CHOIR_AUDITCTL_S = """\
enabled 1
failure 1
pid 299788
rate_limit 200
backlog_limit 8192
lost 2140
backlog 0
backlog_wait_time 60000
backlog_wait_time_actual 0
loginuid_immutable 0 unlocked
"""


class RealChoirAuditctl(unittest.TestCase):
    """The pure parsers against real output captured on the host."""

    def test_the_rendered_expected_watches_match_the_real_listing(self):
        loaded = sva.loaded_rules(CHOIR_AUDITCTL_L)
        for spec in ("/run/agenix.d:rwa:agenix-secrets", "/etc/sudoers:wa:sudoers"):
            self.assertTrue(sva.expected_rule_lines(spec) & loaded, spec)

    def test_a_narrowed_real_rule_does_not_match(self):
        narrowed = CHOIR_AUDITCTL_L.replace("-w /etc/sudoers -p wa -k sudoers", "-w /etc/sudoers -p w -k sudoers")
        self.assertFalse(sva.expected_rule_lines("/etc/sudoers:wa:sudoers") & sva.loaded_rules(narrowed))

    def test_the_real_status_parses(self):
        self.assertEqual(sva.audit_status(CHOIR_AUDITCTL_S), (1, 2140, 299788))


class BansStampScript(unittest.TestCase):
    """modules/services/soc-bans-stamp.sh: two mtimes from one exit status."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.bin = os.path.join(self.d, "bin")
        os.mkdir(self.bin)
        fake_touch(self.bin)
        self.bans = os.path.join(self.d, "bans")
        self.health = os.path.join(self.d, "health")

    def run_it(self, **kw):
        return run_script(BANS_STAMP_SCRIPT, {"SANCTA_DOCTRINE_STAMP": self.bans, "SOC_HEALTH_STAMP": self.health},
                          bindir=self.bin, **kw)

    def mt(self, path):
        return int(os.stat(path).st_mtime)

    def fresh(self, path):
        return abs(time.time() - self.mt(path)) < 60

    def test_clean_run_freshens_both(self):
        self.assertEqual(self.run_it(), 0)
        self.assertTrue(self.fresh(self.bans) and self.fresh(self.health))

    def test_exit_one_is_a_ban_and_only_the_bans_stamp_goes_red(self):
        self.assertEqual(self.run_it(result="exit-code", status="1"), 0)
        self.assertEqual(self.mt(self.bans), 1)
        self.assertTrue(self.fresh(self.health))

    def test_exit_three_a_ban_plus_an_unreadable_source_turns_both_red(self):
        self.assertEqual(self.run_it(result="exit-code", status="3"), 0)
        self.assertEqual((self.mt(self.bans), self.mt(self.health)), (1, 1))

    def test_exit_two_crash_timeout_and_signal_only_turn_health_red(self):
        for kw in (dict(result="exit-code", status="2"), dict(result="exit-code", status="137"),
                   dict(result="timeout", code="killed", status="TERM"), dict(result="signal", code="killed", status="SEGV"),
                   dict(result="", code="", status="")):
            self.assertEqual(self.run_it(**kw), 0, kw)
            self.assertTrue(self.fresh(self.bans), kw)
            self.assertEqual(self.mt(self.health), 1, kw)

    def test_an_evaluator_error_after_a_ban_keeps_the_bans_stamp_red(self):
        # A blind run must not clear a ban that may still be in place.
        self.assertEqual(self.run_it(result="exit-code", status="1"), 0)
        self.assertEqual(self.mt(self.bans), 1)
        for kw in (dict(result="exit-code", status="2"), dict(result="timeout", code="killed", status="TERM")):
            self.assertEqual(self.run_it(**kw), 0, kw)
            self.assertEqual(self.mt(self.bans), 1, kw)
            self.assertEqual(self.mt(self.health), 1, kw)
        # A clean run afterwards clears it as usual.
        self.assertEqual(self.run_it(), 0)
        self.assertTrue(self.fresh(self.bans))

    def test_a_failed_write_never_leaves_an_old_fresh_stamp(self):
        for p in (self.bans, self.health):
            with open(p, "w"):
                pass
        self.assertNotEqual(self.run_it(fail="plain"), 0)
        self.assertEqual((self.mt(self.bans), self.mt(self.health)), (1, 1))

    def test_double_failure_removes_the_stamps_and_fails(self):
        for p in (self.bans, self.health):
            with open(p, "w"):
                pass
        self.assertNotEqual(self.run_it(fail="all"), 0)
        self.assertFalse(os.path.exists(self.bans) or os.path.exists(self.health))

    def test_missing_variables_fail_loudly(self):
        import subprocess
        import shutil
        bash = shutil.which("bash") or "/bin/bash"
        r = subprocess.run([bash, BANS_STAMP_SCRIPT], env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")}, capture_output=True)
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
