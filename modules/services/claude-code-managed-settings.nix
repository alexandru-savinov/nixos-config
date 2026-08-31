# claude-code-managed-settings — the settings a running session cannot erase.
#
# WHY THIS EXISTS
# ----------------
# 2026-08-20: ~/.claude/settings.json on sancta-choir silently lost the
# status-bar and clock-hook keys TWICE the same day (hand-restored 07:10 and
# 07:29, both gone again by mtime 16:20). Evidence, live:
#
#   jq -e '(.hooks.UserPromptSubmit // []) | length > 0' settings.json  -> FAIL
#   jq -e '.statusLine.command // "" | length > 0' settings.json        -> FAIL
#   jq -r 'keys|join(", ")' settings.json ->
#     agentPushNotifEnabled, effortLevel, enabledPlugins, env,
#     extraKnownMarketplaces, model, permissions, skipAutoPermissionPrompt,
#     skipDangerousModePermissionPrompt, verbose, voiceEnabled
#
# `effortLevel` and `model` are exactly what the interactive `/model` command
# and the effort switch write. The harness rewrites the WHOLE file from its
# own in-memory copy on that write — a copy that never saw keys added
# EXTERNALLY (by hand, or by Nix/home-manager) after the session started. Any
# key not present when the harness loaded settings.json is gone the next time
# any session touches `/model` or the effort switch, no matter how it got
# there. The same event killed the clock hook and the status bar together on
# 2026-08-07 (they died the same minute) — this is not a one-off, it is a
# mechanism, and hand-restoration into that file is futile while a session
# lives.
#
# THE FIX: Claude Code also reads /etc/claude-code/managed-settings.json on
# Linux (official docs, verified 2026-08-20). Managed settings sit at the TOP
# of the precedence chain — above local, project, and user settings — and are
# read fresh from disk each time, never round-tripped through the harness's
# in-memory settings object. A file the harness does not own cannot be a file
# the harness silently rewrites.
#
# WHAT GOES IN HERE, AND THE HARD LIMIT ON IT
# --------------------------------------------
# Managed settings OVERRIDE the owner's own settings.json for any key they
# set. That makes this file a standing capability grant, not a convenience.
# The original rule was "EXACTLY four keys and nothing else, do not add a
# fifth without re-litigating this comment."
#
# RE-LITIGATED 2026-08-26 — the rule is now a TEST, not a count. What may
# live here is: (a) agent INFRASTRUCTURE whose loss makes the agent invisible
# or unaccountable, and (b) restrictions on the AGENT's own behaviour. What
# may NOT live here is any OWNER PREFERENCE — those stay sancta-scoped in
# home-manager.users.sancta.programs.claude-code.extraSettings, which is why
# model / verbose / spinnerTipsEnabled are still over there and not in this
# file. That boundary is the thing the original rule was actually protecting;
# a headcount was only ever a proxy for it. Anything that fails the test still
# turns "the harness can't erase infrastructure" into "Nix quietly outranks
# the owner's own preferences," which remains the opposite of this module's
# purpose.
#
# What forced the re-litigation: the whole hook registry — not just the four
# keys below — is subject to the same erasure defect, and had in fact been
# erased again. Evidence, 2026-08-26:
#
#   systemctl show home-manager-sancta -p ExecMainExitTimestamp
#     -> Tue 2026-08-25 23:54:30 EEST      (last home-manager activation)
#   stat -c %y /var/lib/sancta/.claude/settings.json
#     -> 2026-08-26 10:14:06 +0300          (rewritten 10h20m LATER)
#   jq '.hooks|keys' /var/lib/sancta/.claude/settings.json
#     -> null                               (no hooks at all)
#
# TWO writers clobber that file, and they need different fixes:
#
#   1. The 23:54 boot activation. claude-shared's `home.activation.
#      claudeSettings` installs the merged declarative settings over
#      ~/.claude/settings.json whenever the hash differs. Hooks added by hand
#      are not in that set, so a rebuild or a boot drops them. This one is
#      at least fixable declaratively — put the hooks in the Nix set.
#   2. The 10:14 rewrite. No home-manager run happened between 23:54:30 and
#      10:14:06 (timestamps above), so home-manager CANNOT be that writer.
#      It is the interactive harness doing what this header already
#      documented on 2026-08-20: rewriting the WHOLE file from an in-memory
#      copy that never saw an externally-added key. This one is NOT fixable
#      in ~/.claude/settings.json by any mechanism — not a hand edit, not a
#      Nix `install`, not a jq merge at activation time. All three restore
#      hooks that the next `/model` or effort-switch write erases again,
#      typically within hours, exactly as happened overnight.
#
# So the hook registry moved HERE rather than into the home-manager settings
# set: fixing writer 1 alone would have shipped a fix that looks declarative
# and still loses the hooks by lunchtime. Five of sancta's six candidate
# events moved; SessionStart/SessionEnd did not, for a reason that has nothing
# to do with durability — see HERDR COLLISION below.
#
# Consolidating also RETIRES the unresolved merge-semantics risk named in the
# HOOK PRECEDENCE section below, for sancta. With none of her hooks left in
# ~/.claude/settings.json, whether the managed layer merges or replaces a
# same-event array no longer decides whether any of them fires — declaring
# some here and some there would have meant a "replace" answer silently
# killing the user-side half. That same reasoning is what rules SessionStart
# OUT: there the user-side half belongs to herdr, and this file cannot
# consolidate what it does not own.
#
#   1. statusLine   — the one surface that never scrolls away; it was dark
#                      for 12 days because of this exact defect.
#   2. hooks.UserPromptSubmit (`date`) — without it the agent cannot know the
#                      real time of a message and has repeatedly mis-stated
#                      timing as a result.
#   3. hooks.PostToolUse (memory-index-hook) — keeps MEMORY.md derived from
#                      the memory files' frontmatter; without it the recall
#                      index silently drifts from what is actually on disk.
#   4. hooks.Stop (evidence-gate) — RE-LITIGATED 2026-08-23, added on
#                      Alexandru's explicit order ("I need the mechanism that
#                      you'll fix that", 13:57, after three unverified
#                      system-state assertions in one day). It fires only
#                      when a turn makes a system-state claim having run ZERO
#                      tools, and nudges once per turn (stop_hook_active
#                      short-circuit — the sq047 anti-loop designed in). It
#                      restricts the AGENT's own output; it takes nothing
#                      from the owner — which is why it passes this header's
#                      bar. It lives here and not in ~/.claude/settings.json
#                      because that file is exactly what the harness rewrites
#                      from memory on /model — an accountability hook that
#                      the harness can silently drop is decoration.
#   5. the procstate wiring (UserPromptSubmit, PostToolUse `*`, Notification
#                      `permission_prompt`, Stop — NOT SessionStart/SessionEnd,
#                      see HERDR COLLISION) — ADDED 2026-08-26. Each calls
#                      sancta-procstate, which writes the main session's
#                      state to ~/.claude/index/statusline/procstate for the
#                      Mac-side poller (darwin-config sancta-bridge) to paint
#                      the `sancta` agterm row. Same class as key 1: it is a
#                      STATUS SURFACE, it emits state and takes nothing from
#                      anyone, and when it dies the failure mode is the one
#                      key 1 already cost 12 days to — a dark bar that looks
#                      like a stuck agent. The Mac poller cannot tell "no
#                      hooks registered" from "agent wedged", which is why a
#                      silently-erasable registry is not good enough here.
#   6. hooks.PreToolUse (transcript-scan-guard, Bash) — ADDED 2026-08-26.
#                      Guards Bash calls against dragging raw transcript
#                      content into a command. Same class as key 4: it
#                      restricts what the AGENT may do and takes nothing from
#                      the owner, and a guard the harness can silently drop
#                      is — as key 4 puts it — decoration. It is the one
#                      command here rendered by guardedBlockingCommand rather
#                      than guardedSoulCommand, because a guard that fails
#                      OPEN when its script is missing is decoration of a
#                      subtler kind: see that helper's comment.
#   7. hooks.PostToolUse (pipe-status-advisor, Bash) — ADDED 2026-08-26.
#                      The weakest of the set on its own merits: it is
#                      advisory, it only tells the agent when a pipeline's
#                      exit status hid a failure. It is here for a structural
#                      reason rather than a stakes-based one — this module
#                      sets hooks.PostToolUse, and per the unresolved
#                      question in HOOK PRECEDENCE below, that may replace a
#                      user-side PostToolUse array wholesale. Leaving this
#                      one hook in ~/.claude/settings.json would make it the
#                      single member of the registry whose firing depends on
#                      an answer nobody has. The alternative was to drop it;
#                      it earns its place by being cheap, read-only, and
#                      already relied on.
#   8. hooks.UserPromptSubmit (goal-sau-guard) — ADDED 2026-08-26, same day
#                      and for the same structural reason as key 7: this
#                      module already sets hooks.UserPromptSubmit (the
#                      clock, key 2), so under the same unresolved
#                      HOOK PRECEDENCE question a user-side-only
#                      UserPromptSubmit array risks silent replacement rather
#                      than merge. Its own stakes are real on their own,
#                      though: it enforces the "SAU Alexandru spune
#                      stop/amână" clause any `/goal` condition needs — an
#                      observable closing fact is not enough on its own
#                      (feedback_hook_loop_presence.md, 2026-07-20) — a rule
#                      that regressed a second time on 2026-08-26 (recidiva).
#                      It restricts the AGENT's own /goal-setting behaviour
#                      and takes nothing from the owner, same class as key 4;
#                      a nudge the harness can silently drop is decoration
#                      the day the clause actually matters. Guarded like
#                      every other soul-volume command; not a PreToolUse
#                      block (it advises the agent composing the /goal, it
#                      does not gate a tool call), so it renders via
#                      guardedSoulCommand/hookEntry like keys 2-3 rather than
#                      guardedBlockingCommand like key 6.
#   9. hooks.PreToolUse (comanda-distructiva, Bash) — ADDED 2026-08-31.
#                      Second member of key 6's class, and rendered the same
#                      way for the same reason. It stops a small set of
#                      irrecoverable shapes — `rm -r` at a protected root,
#                      mkfs, dd onto a block device, curl-piped-to-shell — and
#                      its whole point is that it EXPLAINS: a block with no
#                      reason produces a blind retry, usually phrased more
#                      circuitously, which is the behaviour being guarded
#                      against. Its stderr therefore names what matched, why
#                      not on this host, and what to do instead.
#
#                      It is a TRIPWIRE ON ACCIDENTAL SHAPES, not containment,
#                      and the source says so in its own header and in every
#                      block message. The wall against deletion is filesystem
#                      permissions and the weekly soul-mirror; anyone treating
#                      a regex over a command string as protection has built
#                      the dangerous green this repo keeps re-learning about.
#
#                      Reviewed before wiring (revmux, 4 independent Opus
#                      lenses): 14 findings, 11 confirmed, 13 fixed and 1
#                      refused in writing. The refusal and the full
#                      disposition table live on the soul volume, at
#                      index/moments/garda-distructiva-recenzie.md — not here,
#                      because a public repo is the wrong place for a
#                      shape-by-shape map of what a guard on this host does
#                      and does not catch.
#
#                      A false positive kills this guard as surely as a miss:
#                      one block on a command that runs every day and it gets
#                      switched off. So the negative arm asserts BOTH
#                      directions (34 dangerous shapes blocked, 29 everyday
#                      ones allowed) and asserts the message text, not just
#                      the exit code — four deliberate mutations were run to
#                      confirm the arm can actually go red.
#
# HERDR COLLISION — WHY SessionStart/SessionEnd ARE NOT HERE
# ------------------------------------------------------------
# (2026-08-26, PR #584 review finding MEDIUM.) This file is machine-wide, and
# widening it from 3 hook events to nearly every event type raises a question
# the earlier three never did: does any OTHER account on this host register
# hooks of its own? Audited, live:
#
#   jq -S '.hooks' /var/lib/herdr/.claude/settings.json
#     -> { "SessionStart": [ { "matcher": "*", "hooks": [ { "type":
#          "command", "timeout": 10, "command": "bash '/var/lib/herdr/
#          .claude/hooks/herdr-agent-state.sh' session" } ] } ] }
#   jq '.hooks' /root/.claude/settings.json          -> none
#
# So herdr DOES, on exactly one event — and it is SessionStart, which the
# procstate wiring wanted too. herdr-server reinstalls that hook on every
# start (`herdr integration install claude`, modules/services/herdr.nix), and
# hosts/sancta-choir/configuration.nix already documents it being clobbered
# once by home-manager. But a reinstall cannot defend against THIS: the losing
# side would be a lower-precedence file that is still perfectly intact, not a
# missing key, so herdr would rewrite a hook that keeps on not firing and its
# dashboard would silently stop reflecting agent state.
#
# Whether that actually happens depends on the merge-vs-replace question in
# HOOK PRECEDENCE, which remains unresolved and untestable from here. Under
# "concatenate" both fire and all is well; under "replace" herdr's hook dies
# silently. Two ways out were considered:
#
#   - Duplicate herdr's command into this file, guarded to the herdr identity,
#     so it survives either way. REJECTED: herdr's own hook script says
#     "managed by herdr; reinstalling or updating the integration overwrites
#     this file" and carries a HERDR_INTEGRATION_VERSION. Pinning another
#     module's versioned private internals here means a herdr upgrade silently
#     leaves this file rendering the OLD command — trading a possible failure
#     for a guaranteed future one.
#   - Don't claim the event. TAKEN.
#
# It costs the least of the seven candidates. procstate still updates on every
# prompt, every tool call, every permission prompt and every turn end, which is
# what actually drives the agterm row minute to minute; Stop already carries
# `--auto-reset`. The only lost behaviour is the idle reset in the window
# between a session starting and its first prompt. Revisit if the merge
# semantics are ever established empirically (that experiment needs write
# access to a real /etc, which is why it has never been run), or if herdr's
# SessionStart hook and the procstate wiring are ever designed together.
#
# spinnerTipsEnabled is deliberately NOT in this file — see the P1
# CROSS-USER SAFETY section below for why (a PREFERENCE, not infrastructure,
# that a single machine-wide JSON literal cannot scope to one account; its
# durable home is home-manager.users.sancta.programs.claude-code.extraSettings
# in hosts/sancta-choir/configuration.nix instead).
#
# CROSS-USER SAFETY (2026-08-20, PR #569 finding P1)
# ----------------------------------------------------
# This file is MACHINE-WIDE — every account Claude Code is installed for on
# this host (root, herdr, sancta; hosts/sancta-choir/configuration.nix:64-73)
# reads the SAME copy. Each of the three keys was audited for what a NON-
# sancta session does with it:
#
#   - hooks.UserPromptSubmit (`date ...`) — no filesystem path, no soul-volume
#     dependency. Confirmed harmless for any account; left unguarded.
#   - statusLine and hooks.PostToolUse (memory-index-hook) both point at
#     scripts under /var/lib/sancta, which is 0700 sancta:sancta at every
#     level (sancta-worker.nix's tmpfiles rule — the LUKS soul volume's
#     privacy boundary, never to be loosened for this). A non-sancta account's
#     exec of either path fails at the KERNEL's path-resolution step, before
#     the target script's own code ever runs — so no in-script defense can
#     close this; the guard has to live in the command Nix renders here. Both
#     are wrapped in `guardedSoulCommand` below: `id -un` is safe to run as
#     any account and touches nothing under /var/lib/sancta, so it gates the
#     `exec` before the unreachable (herdr) or meaningless (root, which
#     bypasses DAC and WOULD reach the script, just with no sancta state to
#     render) path is ever touched.
#
# HOOK PRECEDENCE IS UNVERIFIED — AND THE MODULE IS DESIGNED NOT TO CARE
# ------------------------------------------------------------------------
# (2026-08-20, PR #569 finding MEDIUM) It was never established empirically
# whether the managed layer MERGES its hooks.UserPromptSubmit / PostToolUse
# arrays with a same-event array in ~/.claude/settings.json, or replaces that
# top-level key wholesale. That could not be tested on this host: Claude
# Code's managed-settings path (/etc/claude-code/managed-settings.json on
# Linux) has no documented environment-variable override — confirmed via
# claude-code-guide 2026-08-20 and independently checked by grepping the
# installed 2.1.219 binary for any "managed"-related string (none found) —
# and CLAUDE_CONFIG_DIR affects only the USER config directory, not the
# managed one. Redirecting it for a real empirical test would require writing
# to the real /etc, i.e. root, which this session does not have. The one
# documented signal (settings.md, "Merge Semantics for Arrays and Objects":
# arrays concatenate and de-duplicate across scopes) is a GENERAL rule, not a
# hooks-specific confirmation, so it is evidence, not proof.
#
# Rather than ship on that assumption, THIS MODULE DOES NOT DEPEND ON THE
# ANSWER: it makes no assumption that any hook a user adds to
# ~/.claude/settings.json for UserPromptSubmit or PostToolUse will keep
# firing once this module is enabled. Verified 2026-08-20: sancta's own
# settings.json currently has `"hooks": null` (`jq '.hooks' settings.json`)
# — the interactive-harness regression this whole module exists to fix had
# already erased whatever was there, so there is nothing at stake today under
# either interpretation. If a user-side UserPromptSubmit/PostToolUse hook is
# ever added by hand in the future, whether it ALSO fires depends on this
# unresolved question — that risk is named here deliberately rather than
# discovered by a hook silently going quiet.
#
# 2026-08-26: still unresolved, and now deliberately UNREACHABLE for this
# host's registry. Re-verified the same day that sancta's settings.json again
# has no hooks key at all (`jq '.hooks|keys'` -> null), so nothing is at stake
# under either interpretation today — and because this module now carries
# every hook rather than a subset, no hook's firing depends on the answer.
# The question only bites again if someone re-adds a hook to
# ~/.claude/settings.json for an event this file also sets; the right move
# then is to add it HERE, not there, which is also what durability demands.
#
# THE WORKS-BY-LUCK TRAP (same class as sancta-statusline-refresh.nix)
# ----------------------------------------------------------------------
# Every command below except the clock points at a path on the LUKS SOUL
# VOLUME (/var/lib/sancta/.claude/...), not a Nix store path — seven distinct
# scripts as of 2026-08-26 (statusline.sh, memory-index-hook, evidence-gate,
# transcript-scan-guard, pipe-status-advisor, sancta-procstate,
# goal-sau-guard). That means:
#   - tests/unit-script-refs.nix cannot see them — it only resolves
#     /nix/store/... references, by construction. The ONE exception since
#     2026-08-26 is the `timeout` in guardedBlockingCommand, which is a store
#     path precisely so that the mechanism keeping a guard fail-closed is not
#     itself subject to this trap.
#   - A missing interpreter, a missing script, or a lost execute bit on any
#     of those paths fails at RUNTIME (the hook silently does nothing, or the
#     UserPromptSubmit hook errors on every prompt), never at build or eval
#     time. `nixos-rebuild dry-build` going green proves this JSON renders
#     correctly; it proves nothing about whether the scripts it points at
#     still exist and are executable on the day someone reads this. The
#     post-deploy check in the PR that added the registry exists for exactly
#     this gap: eval cannot close it, only running the agent can.
# As of 2026-08-20, tests/execstart-path-contract.nix (PR #568, the
# purpose-built eval-time guard for exactly this class of bug) is NOT yet on
# main — it is an open PR (state: OPEN, branch add/execstart-path-contract-
# check). It also only covers systemd unit ExecStart-family fields, not
# arbitrary settings.json hook commands, so these two paths would not fit its
# existing manifest shape without extending it to a new kind of target. Left
# out of that PR's scope deliberately rather than folded in speculatively;
# revisit when #568 lands and ideally scope it to hook commands too, not just
# systemd Exec lines.
#
# FILE MODE: root:root, 0644 (world-readable, not writable). Ownership/mode
# for managed-settings.json is UNDOCUMENTED upstream as of 2026-08-20; this is
# a conservative default — every account on the box can read it (matching
# `~/.claude/settings.json`'s own 0644), nothing but root/Nix can write it.
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkEnableOption mkOption types;
  cfg = config.services.claudeCodeManagedSettings;

  # 2026-08-20, PR #569 finding P1: this /etc file is MACHINE-WIDE, but
  # hosts/sancta-choir/configuration.nix installs Claude Code for root, herdr
  # AND sancta. statuslineScript and memoryIndexHookScript both point under
  # /var/lib/sancta, which is 0700 sancta:sancta at every level down to
  # .claude (sancta-worker.nix's tmpfiles rule — the LUKS soul volume's
  # privacy boundary, not to be loosened for this or any other reason). That
  # means a non-sancta account's attempt to exec either script fails at the
  # KERNEL's path-resolution step (EACCES on the missing search bit on the
  # parent directories) before a single line of the target script ever runs —
  # no amount of defensive code INSIDE those scripts can catch that, because
  # they are never reached. Root is the other half of the problem: root
  # bypasses DAC checks entirely, so it WOULD reach the scripts, just with no
  # meaningful state to render (its own $HOME, not sancta's).
  #
  # The fix has to live in the command Nix renders here, not in the target
  # scripts: `id -un` costs nothing, touches nothing under /var/lib/sancta,
  # and is safe to run as literally any account — so it can gate the `exec`
  # BEFORE the unreachable/meaningless path is ever touched. For herdr this
  # turns "permission-denied noise on every render/every Write-Edit" into a
  # true instant no-op; for root it turns "renders with no sancta state" into
  # the same no-op, closing both halves of the P1 finding with one mechanism.
  # Verified 2026-08-20: rendering this exact guard and running it under a
  # PATH-shimmed `id` reporting a foreign user touches nothing (history file
  # md5 unchanged) and exits 0; under the real `sancta` identity it reaches
  # the `exec`. See the PR thread for the transcript.
  #
  # Takes a full command line, not just a path: the procstate hooks added
  # 2026-08-26 all pass an argument (`active --blink`, `blocked`, `idle`, …).
  # `exec` handles those exactly as a shell would, and the guard is unchanged
  # by their presence — `id -un` still runs before any soul-volume path is
  # touched.
  guardedSoulCommand = cmdline: ''[ "$(id -un)" = sancta ] && exec ${cmdline}; exit 0'';

  # FAIL-CLOSED variant, for PreToolUse guards only (PR #584 review, P1).
  #
  # guardedSoulCommand above fails OPEN by construction: if `exec` cannot
  # start the target — script deleted, execute bit lost, `node` missing from
  # the hook's PATH — a non-interactive shell exits 126/127 and the trailing
  # `exit 0` never even runs. For a status emitter or an advisory that is the
  # right behaviour. For a PreToolUse GUARD it is the worst possible one: the
  # hook reports success, Claude Code proceeds, and the Bash command the guard
  # exists to stop runs unchecked. The header's WORKS-BY-LUCK TRAP says these
  # soul-volume paths are invisible to every build-time check, so "the script
  # is missing" is a live runtime possibility, not a hypothetical.
  #
  # So: no `exec` (we must survive to inspect the status), non-sancta still
  # exits 0 (herdr/root must never be blocked by sancta's guard), and the
  # status is matched against an ALLOWLIST — only a literal 0 lets the Bash
  # call through. transcript-scan-guard's contract is exactly exit 0 to allow
  # and exit 2 to block (verified on-host 2026-08-26); any other status means
  # it did not deliver a verdict, and a guard with no verdict must not be an
  # implicit yes.
  #
  # This was first written as a DENYLIST — map 124/125/126/127 to a block,
  # pass everything else through — on the reasoning that blocking every
  # non-zero would turn an unrelated crash into a wedged agent. Testing the
  # rendered command killed that: a guard that ignores SIGTERM is escalated to
  # SIGKILL by `timeout -k 2` and reports 137, which the denylist happily
  # passed through as "not a blocking code", i.e. allow. Enumerating the ways
  # a process can fail to answer is whack-a-mole; enumerating the one way it
  # can say yes is not. The wedge risk is real but bounded and LOUD: the
  # matcher is Bash only, so Read/Edit/Write still work to repair the guard,
  # and the status is named on stderr.
  #
  # A HANG is the third way not to complete, and dropping `exec` is what makes
  # it reachable — the status mapping below only runs once the guard returns
  # (2026-08-26, PR #584 review round 2). Claude Code does have its own hook
  # `timeout` field, but whether expiry blocks the tool call or allows it is
  # UNVERIFIED, and "allow" would silently rebuild the exact bypass this
  # helper exists to remove. So the bound is taken here instead, where the
  # outcome is ours to decide: `timeout` fires first and reports 124, which
  # maps to a block like any other did-not-complete. Claude Code's own field
  # is still set (see preToolUseEntry) but only as a backstop, deliberately
  # long enough that it never decides the outcome.
  #
  # `timeout` comes from the store, not PATH — unlike clockCommand's bare
  # `date`, the machinery that makes a guard fail closed must not itself
  # depend on what PATH resolution happens to find at hook-run time.
  guardedBlockingCommand =
    cmdline:
    ''[ "$(id -un)" = sancta ] || exit 0; ${pkgs.coreutils}/bin/timeout -k 2 ${toString cfg.preToolUseGuardTimeout} ${cmdline}; rc=$?; case $rc in 0) exit 0 ;; 2) exit 2 ;; *) echo "managed-settings: PreToolUse guard did not deliver a verdict (status $rc) — blocking" >&2; exit 2 ;; esac'';

  # The four soul-volume hook scripts are invoked DIRECTLY, not as
  # `node <script>`. All three .mjs files carry `#!/usr/bin/env node` and the
  # execute bit (verified on-host 2026-08-26), and sancta-procstate carries
  # `#!/usr/bin/env bash` — so `exec` resolves the interpreter through the
  # shebang. This is the shape key 4 (evidence-gate) has already been firing
  # in since 2026-08-23, which is why it is used for the new ones rather than
  # a second, unproven `node <script>` form.
  procstate = args: guardedSoulCommand "${cfg.procstateScript} ${args}";

  # A hooks-array entry with no matcher (fires on every event of its kind).
  hookEntry = command: { hooks = [{ type = "command"; inherit command; }]; };

  # Same, scoped to the tools/events `matcher` selects.
  matchedEntry = matcher: command: (hookEntry command) // { inherit matcher; };

  # The PreToolUse guard, with Claude Code's own hook timeout set as a
  # BACKSTOP only: guardedBlockingCommand already bounds the guard itself, and
  # this value is deliberately longer so the harness's timeout — whose
  # block-or-allow behaviour on expiry is unverified — never gets to decide
  # the outcome. It exists so that a failure of the inner bound (a `timeout`
  # that somehow cannot run at all) is still bounded by something.
  preToolUseEntry = matcher: command: {
    inherit matcher;
    hooks = [
      {
        type = "command";
        inherit command;
        timeout = cfg.preToolUseGuardTimeout + 10;
      }
    ];
  };

  settings = {
    statusLine = {
      type = "command";
      command = guardedSoulCommand cfg.statuslineScript;
    };
    # Every entry below is a SEPARATE element of its event's array rather than
    # a second command inside one entry: Claude Code runs matching entries
    # independently, so an entry that exits non-zero (evidence-gate nudging,
    # a soul volume that is not mounted) cannot take the unrelated procstate
    # update down with it. Ordering within an array is not depended on.
    hooks = {
      UserPromptSubmit = [
        # Bare `date` — no filesystem path, no soul-volume dependency,
        # confirmed harmless for any account: it prints a timestamp and
        # nothing else, so it is deliberately left UNguarded.
        (hookEntry cfg.clockCommand)
        (hookEntry (procstate "active --blink"))
        # RE-LITIGATED 2026-08-26 (header key 8): the "SAU Alexandru spune
        # stop/amână" clause. Guarded like every other soul-volume command.
        (hookEntry (guardedSoulCommand cfg.goalSauGuardScript))
      ];
      PreToolUse = [
        (preToolUseEntry "Bash" (guardedBlockingCommand cfg.transcriptScanGuardScript))
        # Key 9. Separate array element, not a second command in the entry
        # above, for the reason stated at the top of `settings`: the two
        # guards must be able to fail independently.
        (preToolUseEntry "Bash" (guardedBlockingCommand cfg.destructiveCommandGuardScript))
      ];
      PostToolUse = [
        (matchedEntry "Write|Edit" (guardedSoulCommand cfg.memoryIndexHookScript))
        (matchedEntry "Bash" (guardedSoulCommand cfg.pipeStatusAdvisorScript))
        (matchedEntry "*" (procstate "active --blink"))
      ];
      Notification = [
        (matchedEntry "permission_prompt" (procstate "blocked"))
      ];
      Stop = [
        # Same cross-user shape as the other soul-volume hooks: non-sancta
        # accounts no-op before the 0700 path is touched.
        (hookEntry (guardedSoulCommand cfg.evidenceGateScript))
        (hookEntry (procstate "completed --auto-reset"))
      ];
      # SessionStart / SessionEnd are deliberately ABSENT — see the HERDR
      # COLLISION section in the header. herdr registers its own SessionStart
      # hook in its own settings.json, and claiming that event machine-wide
      # could silently kill it under merge semantics nobody has established.
    };
    # spinnerTipsEnabled deliberately does NOT live here — see finding P1's
    # resolution below: a single /etc file cannot condition a plain JSON
    # boolean per invoking user (unlike a "command" string, a literal has no
    # runtime identity check available to it), and this key is a PREFERENCE,
    # not infrastructure (this module's own header already said so). Applying
    # it machine-wide would take the choice from herdr/root with no way to
    # scope it, for a key whose loss is low-stakes if the interactive harness
    # ever eats it. Its durable home is
    # home-manager.users.sancta.programs.claude-code.extraSettings in
    # hosts/sancta-choir/configuration.nix, sancta-scoped, alongside the
    # model/verbose keys that already live there on the same trade-off.
  };
in
{
  options.services.claudeCodeManagedSettings = {
    enable = mkEnableOption ''
      /etc/claude-code/managed-settings.json — the Claude Code status bar and
      sancta's hook registry, in the one layer the interactive harness cannot
      silently erase (~/.claude/settings.json is rewritten wholesale from the
      harness's in-memory copy on `/model`; see the header's 2026-08-26
      evidence). SessionStart/SessionEnd are deliberately excluded because
      herdr registers its own SessionStart hook on this host — see the
      header's HERDR COLLISION section. Machine-wide by construction (Claude
      Code has no per-user managed-settings location) — every command that
      touches a path under
      /var/lib/sancta is self-guarded to the sancta identity via `id -un` (see
      guardedSoulCommand / the P1 CROSS-USER SAFETY header section) so herdr
      and root sessions on this same host get an instant no-op instead of a
      permission-denied path under the 0700 soul volume.
    '';

    statuslineScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/statusline.sh";
      description = ''
        Path to the status-bar renderer. Lives on the soul volume, not the
        Nix store — see the module header's WORKS-BY-LUCK TRAP note: this
        path is invisible to tests/unit-script-refs.nix, so a missing file
        or a lost execute bit here fails silently at runtime, not at build.
        Wrapped in guardedSoulCommand before rendering, so only a session
        running as `sancta` ever attempts to exec it (see the P1 CROSS-USER
        SAFETY header section).
      '';
    };

    clockCommand = mkOption {
      type = types.str;
      # Matches the format the hook has run historically (see
      # reference-cc-hooks-settings-location.md): a bare `date` alone would
      # still fix the underlying defect, but this is the exact stamp the
      # agent has depended on since 2026-07-24 to avoid mis-stating timing.
      default = "date '+Now: %A %Y-%m-%d %H:%M %Z'";
      description = ''
        Command run on every UserPromptSubmit so the agent has a real
        timestamp for the message. `date` is resolved via PATH at hook-run
        time (not a store path) — same works-by-luck caveat as
        statuslineScript, one level deeper: even the INTERPRETER here is
        whatever `date` PATH resolution finds on the box, not a Nix closure.
      '';
    };

    evidenceGateScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/hooks/evidence-gate.mjs";
      description = ''
        Path to the Stop-hook evidence gate (soul volume, git-tracked in the
        hooks repo, `#!/usr/bin/env node` shebang — must carry the execute
        bit). Fires only when a turn asserts system state with zero tool
        calls; one nudge per turn by construction. Ordered by Alexandru
        2026-08-23 — see the header's key-4 note for why it must live in the
        managed layer. Same works-by-luck caveat as the other soul-volume
        paths: invisible to store-reference checks, fails at runtime only.
      '';
    };

    memoryIndexHookScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/index/bin/memory-index-hook";
      description = ''
        Path to the hook that keeps MEMORY.md derived from the memory files'
        frontmatter after every Write/Edit. Lives on the soul volume — same
        works-by-luck caveat as statuslineScript. Its own JS logic already
        no-ops (and always exits 0) for any file_path outside the memory
        store regardless of the invoking account's $HOME — verified
        2026-08-20 — but that logic is unreachable from a non-sancta account
        anyway (0700 parent dirs), so it is ALSO wrapped in
        guardedSoulCommand before rendering, same as statuslineScript.
      '';
    };

    procstateScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/index/bin/sancta-procstate";
      description = ''
        Path to the agterm status-bridge writer (soul volume, git-tracked in
        the index repo, `#!/usr/bin/env bash`). Called with a state argument
        from six different events; it records ONLY the main session's state
        in ~/.claude/index/statusline/procstate, which the Mac polls every 30s
        (darwin-config sancta-bridge) to paint the `sancta` agterm row. Same
        works-by-luck caveat as statuslineScript — and worse in one respect:
        when this stops firing the Mac row does not go blank, it goes STALE,
        which reads as a wedged agent rather than as a broken hook.
      '';
    };

    transcriptScanGuardScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/hooks/transcript-scan-guard.mjs";
      description = ''
        Path to the PreToolUse guard on Bash (soul volume, git-tracked in the
        hooks repo, `#!/usr/bin/env node` shebang — must carry the execute
        bit). Restricts what the agent may do, so it belongs in the managed
        layer under this module's test (header key 6). Same works-by-luck
        caveat as the other soul-volume paths.
      '';
    };

    destructiveCommandGuardScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/hooks/comanda-distructiva.mjs";
      description = ''
        Path to the second PreToolUse guard on Bash (header key 9). Blocks a
        small set of irrecoverable command shapes and, deliberately, explains
        each block on stderr — the explanation is the product, not decoration,
        because a bare refusal produces a blind retry.

        A TRIPWIRE on accidental shapes, NOT containment: it matches a command
        string with regexes, so anything that hides its argv defeats it and it
        is documented as defeatable in its own header. It buys nothing against
        an adversary and must never be counted as a filesystem boundary.

        Rendered by guardedBlockingCommand for key 6's reason: a guard whose
        script has gone missing must not become an implicit yes. Same
        works-by-luck caveat as every other soul-volume path here — eval
        cannot see it, so the post-deploy check in the PR is what closes the
        gap. Self-test: `comanda-distructiva.mjs --autoproba`, which asserts
        both directions (dangerous blocked, everyday allowed) and the message
        text, and exits non-zero on any failure.
      '';
    };

    preToolUseGuardTimeout = mkOption {
      type = types.ints.positive;
      default = 10;
      description = ''
        Seconds the PreToolUse guard may run before it is killed and the tool
        call is BLOCKED (2026-08-26, PR #584 review round 2). Enforced inside
        the rendered command by coreutils `timeout -k 2`, not by Claude Code's
        own hook timeout — expiry there might allow the call through, which
        would rebuild the fail-open bypass guardedBlockingCommand exists to
        remove. Claude Code's field is still set, to this value plus 10, purely
        as a backstop that should never be the one to fire.

        Raising this raises how long a wedged guard can stall every Bash call;
        lowering it risks blocking legitimate calls when the guard is merely
        slow. 10s matches the timeout herdr chose for its own hook on this
        host.
      '';
    };

    pipeStatusAdvisorScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/hooks/pipe-status-advisor.mjs";
      description = ''
        Path to the PostToolUse advisor on Bash (soul volume, hooks repo,
        `#!/usr/bin/env node`). Advisory only — it flags pipelines whose exit
        status masked a failure. Here for a structural reason rather than its
        own stakes: this module sets hooks.PostToolUse, which may replace a
        user-side array wholesale (see HOOK PRECEDENCE in the header), so
        leaving it in ~/.claude/settings.json would make it the one hook whose
        firing depends on an unresolved question. See header key 7.
      '';
    };

    goalSauGuardScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/hooks/goal-sau-guard.mjs";
      description = ''
        Path to the UserPromptSubmit guardian for the "SAU Alexandru spune
        stop/amână" clause (soul volume, hooks repo, `#!/usr/bin/env node`):
        any `/goal` condition needs an observable closing fact PLUS this
        clause (feedback_hook_loop_presence.md, 2026-07-20), a rule that
        regressed a second time on 2026-08-26. Advisory, like
        pipeStatusAdvisorScript and evidence-gate — it restricts the agent's
        own /goal-setting behaviour and takes nothing from the owner, so it
        belongs in the managed layer under this module's test (header key
        8). Same works-by-luck caveat as the other soul-volume paths:
        invisible to store-reference checks, fails at runtime only.
      '';
    };

    etcPath = mkOption {
      type = types.str;
      default = "claude-code/managed-settings.json";
      description = ''
        Path under /etc that environment.etc renders this to. Claude Code on
        Linux reads /etc/claude-code/managed-settings.json specifically;
        changing this option moves the file somewhere Claude Code will not
        look, so leave it at the default unless upstream's documented path
        changes.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.etc.${cfg.etcPath} = {
      text = builtins.toJSON settings;
      # Conservative default — see FILE MODE note in the header. Managed
      # settings are meant to be readable by whichever account runs Claude
      # Code (not necessarily root), and writable by nothing but root/Nix.
      mode = "0644";
    };
  };
}
