# claude-code-managed-settings — the three keys a running session cannot erase.
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
# set. That makes this file a standing capability grant, not a convenience —
# so it carries EXACTLY the four keys below and nothing else. Do not add a
# fifth without re-litigating this comment: anything more turns "the harness
# can't erase infrastructure" into "Nix quietly outranks the owner's own
# preferences," which is the opposite of what this module is for.
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
# THE WORKS-BY-LUCK TRAP (same class as sancta-statusline-refresh.nix)
# ----------------------------------------------------------------------
# The two hook commands below point at paths on the LUKS SOUL VOLUME
# (/var/lib/sancta/.claude/...), not Nix store paths. That means:
#   - tests/unit-script-refs.nix cannot see them — it only resolves
#     /nix/store/... references, by construction.
#   - A missing interpreter, a missing script, or a lost execute bit on
#     either path fails at RUNTIME (the hook silently does nothing, or the
#     UserPromptSubmit hook errors on every prompt), never at build or eval
#     time. `nixos-rebuild dry-build` going green proves this JSON renders
#     correctly; it proves nothing about whether the two scripts it points at
#     still exist and are executable on the day someone reads this.
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
  guardedSoulCommand = path: ''[ "$(id -un)" = sancta ] && exec ${path}; exit 0'';

  settings = {
    statusLine = {
      type = "command";
      command = guardedSoulCommand cfg.statuslineScript;
    };
    hooks = {
      UserPromptSubmit = [
        {
          hooks = [
            {
              type = "command";
              # Bare `date` — no filesystem path, no soul-volume dependency,
              # confirmed harmless for any account: it prints a timestamp and
              # nothing else, so it is deliberately left UNguarded.
              command = cfg.clockCommand;
            }
          ];
        }
      ];
      PostToolUse = [
        {
          matcher = "Write|Edit";
          hooks = [
            {
              type = "command";
              command = guardedSoulCommand cfg.memoryIndexHookScript;
            }
          ];
        }
      ];
      Stop = [
        {
          hooks = [
            {
              type = "command";
              # Same cross-user shape as the other two soul-volume hooks:
              # non-sancta accounts no-op before the 0700 path is touched.
              command = guardedSoulCommand cfg.evidenceGateScript;
            }
          ];
        }
      ];
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
      /etc/claude-code/managed-settings.json — the three Claude Code settings
      keys the interactive harness must never be able to silently erase
      (status bar, clock hook, memory-index hook). Machine-wide by
      construction (Claude Code has no per-user managed-settings location) —
      the status bar and memory-index hook are self-guarded to the sancta
      identity via `id -un` (see guardedSoulCommand / the P1 CROSS-USER
      SAFETY header section) so herdr and root sessions on this same host get
      an instant no-op instead of a permission-denied path under the 0700
      soul volume.
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
