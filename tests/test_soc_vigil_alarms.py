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
        # Injected stand-ins for /run/current-system and /etc/sudoers.
        self.cs = os.path.join(self.d, "current-system")
        self.sudoers = os.path.join(self.d, "sudoers")
        self.last_system = os.path.join(self.sd, "audit.last-system")
        self.stamp = os.path.join(self.d, "stamp")
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
                "--auditctl", self.auditctl, "--stamp", self.stamp]

    def make_auditctl(self, *, enabled=1, lost=0, rules=None, status_exit=0, rules_exit=0):
        rules = HEALTHY_RULES if rules is None else rules
        return fake(self.d, "auditctl", (
            f'echo "$@" >> {self.log}.auditctl\n'
            'case "$1" in\n'
            f'  -s) [ {status_exit} -ne 0 ] && {{ echo boom >&2; exit {status_exit}; }}\n'
            f'      printf "enabled {enabled}\\nfailure 1\\npid 1\\nrate_limit 0\\nbacklog_limit 8192\\nlost {lost}\\nbacklog 0\\n";;\n'
            f'  -l) [ {rules_exit} -ne 0 ] && {{ echo boom >&2; exit {rules_exit}; }}\n'
            f"      cat <<'E'\n{rules}E\n;;\n"
            'esac\n'
        ))

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
        return self.stamp_like_execstoppost(
            sva.main(["audit", "--ausearch", ausearch, "--systemctl", systemctl,
                      "--require-active", "auditd.service", "--require-active", "audit-rules-nixos.service",
                      "--state-dir", self.sd, "--hold", str(hold)] + self.injected()))

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

    def test_missing_stamp_on_the_first_run_is_not_an_error(self):
        self.assertFalse(os.path.exists(self.stamp))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_invalid_stamp_is_not_a_missing_stamp(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        os.utime(self.stamp, (1, 1))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_no_stamp_path_is_an_error(self):
        args = [x for x in self.injected() if x != "--stamp"]
        args = args[:-1] if args[-1] == self.stamp else args
        a = self.ausearch(QUIET)
        systemctl = fake(self.d, "systemctl", "exit 0\n")
        env = os.environ.pop("SANCTA_DOCTRINE_STAMP", None)
        try:
            self.assertEqual(sva.main(["audit", "--ausearch", a, "--systemctl", systemctl,
                                       "--require-active", "auditd.service",
                                       "--state-dir", self.sd, "--hold", "900"] + args
                                      + ["--stamp", ""]), 2)
        finally:
            if env is not None:
                os.environ["SANCTA_DOCTRINE_STAMP"] = env

    def test_bans_missing_stamp_after_a_completed_run_is_an_error(self):
        status = f2b("203.0.113.9").replace("\t", " ")
        ok = (f"echo null\n", f"cat <<'E'\n{status}E\n")
        self.assertEqual(self.bans(*ok), 0)
        os.unlink(self.stamp)
        self.assertEqual(self.bans(*ok), 2)
        self.assertEqual(int(os.stat(self.stamp).st_mtime), 1)
        self.assertEqual(self.bans(*ok), 0)

    # ── ausearch edge cases: each is an evaluator error ──
    def fixture_cmd(self, text):
        fixture = os.path.join(self.d, "fixture")
        with open(fixture, "w") as fh:
            fh.write(text)
        return f"cat {fixture}\n"

    def test_checkpoint_mismatch_is_an_error_not_a_silent_retry(self):
        # Was: a silent retry from the checkpoint's timestamp, exit 0.
        open(self.cp, "w").close()
        a = self.ausearch('case "$*" in *"--start checkpoint"*) exit 1;; esac\nexit 12\n')
        self.assertEqual(self.audit(a), 2)
        args = slurp(self.log).splitlines()
        self.assertEqual(len(args), 2)
        self.assertNotIn("--start recent", args[0])
        self.assertIn("--start checkpoint", args[1])
        self.assertTrue(os.path.exists(os.path.join(self.sd, "audit.checkpoint-mismatch")))

    def test_checkpoint_mismatch_keeps_the_hits_of_the_retry_as_alarms(self):
        for status in (10, 11, 12):
            for f in os.listdir(self.sd):
                os.unlink(os.path.join(self.sd, f))
            open(self.cp, "w").close()
            body = self.fixture_cmd(login_reads_agenix() + "\n")
            a = self.ausearch(f'case "$*" in *"--start checkpoint"*) {body};; esac\nexit {status}\n')
            rc, out = self.run_logged(a)
            self.assertEqual(rc, 2, status)
            self.assertIn("ALARM audit", out)
            self.assertTrue(os.path.exists(self.last), "a retry hit starts the hold")

    def test_checkpoint_mismatch_stays_an_error_until_reconciled(self):
        open(self.cp, "w").close()
        bad = self.ausearch('case "$*" in *"--start checkpoint"*) exit 1;; esac\nexit 12\n')
        self.assertEqual(self.audit(bad), 2)
        # Next runs are quiet and well-formed, but nothing reconciled it.
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 2)
        os.unlink(os.path.join(self.sd, "audit.checkpoint-mismatch"))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 1)  # hold from the mismatch run
        with open(self.last, "w") as fh:
            fh.write(f"{time.time() - 901:.0f}\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

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
    ADVANCING = (
        'cp=; prev=\n'
        'for x in "$@"; do [ "$prev" = --checkpoint ] && cp=$x; prev=$x; done\n'
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

    # ── trail health: auditctl -s / -l, before a quiet window is accepted ──
    def test_trail_health_checked_before_a_quiet_window(self):
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(slurp(self.log + ".auditctl").split(), ["-s", "-l"])

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
            "-a always,exit -F arch=b64 -S openat -F path=/etc/sudoers -F key=sudoers\n"
            "-a always,exit -F arch=b64 -S openat -F dir=/run/agenix -F key=agenix-secrets\n"))
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_first_run_stores_the_lost_counter_without_alarm(self):
        self.auditctl = self.make_auditctl(lost=7)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.assertEqual(slurp(os.path.join(self.sd, "audit.last-lost")).strip(), "7")

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
        self.assertEqual(slurp(os.path.join(self.sd, "audit.last-lost")).strip(), "9")
        # A single blip must not read clean on the next quiet window ...
        self.assertEqual(self.audit(self.ausearch(QUIET)), 1)
        # ... and clears once the hold has elapsed.
        with open(self.last, "w") as fh:
            fh.write(f"{time.time() - 901:.0f}\n")
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

    def test_lost_counter_reset_is_not_an_alarm(self):
        self.auditctl = self.make_auditctl(lost=9)
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)
        self.auditctl = self.make_auditctl(lost=0)  # auditd restarted
        self.assertEqual(self.audit(self.ausearch(QUIET)), 0)

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
        return self.stamp_like_execstoppost(
            sva.main(["bans", "--cscli", fake(self.d, "cscli", guard + cscli_body),
                      "--fail2ban-client", fake(self.d, "f2b", f2b_body),
                      "--cidrs", ",".join(NEVER_BAN),
                      "--state-dir", self.sd, "--stamp", self.stamp]))

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


STAMP_SCRIPT = os.environ.get(
    "SOC_STAMP_SCRIPT",
    os.path.join(HERE, "..", "modules", "services", "sancta-doctrine-guard-stamp.sh"),
)


class StampScript(unittest.TestCase):
    """modules/services/sancta-doctrine-guard-stamp.sh, run for real with a
    stand-in `touch` that can be made to fail (BSD touch has no -d @N)."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.bin = os.path.join(self.d, "bin")
        os.mkdir(self.bin)
        self.stamp = os.path.join(self.d, "stamp")
        py = os.path.realpath(__import__("sys").executable)
        # fail=all|plain|none: which touch calls fail. `-d @N` sets mtime N.
        fake(self.bin, "touch", (
            'mode=plain; [ "$1" = -d ] && mode=epoch\n'
            'case "$STAMP_TOUCH_FAIL" in all) exit 1;; "$mode") exit 1;; esac\n'
            f'if [ "$mode" = epoch ]; then t=${{2#@}}; else t=$(date +%s); fi\n'
            f'exec {py} -c "import os,sys; open(sys.argv[2],\'a\').close(); os.utime(sys.argv[2],(int(sys.argv[1]),)*2)" "$t" "$stamp_path"\n'
        ).replace('"$stamp_path"', '"$STAMP_PATH"'))

    def run_stamp(self, *, result="success", code="exited", status="0", fail="none"):
        env = {"PATH": self.bin + ":/usr/bin:/bin", "SANCTA_DOCTRINE_STAMP": self.stamp,
               "STAMP_PATH": self.stamp, "STAMP_TOUCH_FAIL": fail,
               "SERVICE_RESULT": result, "EXIT_CODE": code, "EXIT_STATUS": status}
        import subprocess
        return subprocess.run(["bash", STAMP_SCRIPT], env=env, capture_output=True, text=True).returncode

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
