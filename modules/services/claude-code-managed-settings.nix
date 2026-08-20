# claude-code-managed-settings — the four keys a running session cannot erase.
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
#   4. spinnerTipsEnabled = false — the owner's own standing preference (the
#                      generic CC tips, off), included here only because it
#                      happens to live at this same layer; NOT infrastructure,
#                      kept minimal and explicit rather than smuggled in.
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

  settings = {
    statusLine = {
      type = "command";
      command = cfg.statuslineScript;
    };
    hooks = {
      UserPromptSubmit = [
        {
          hooks = [
            {
              type = "command";
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
              command = cfg.memoryIndexHookScript;
            }
          ];
        }
      ];
    };
    spinnerTipsEnabled = false;
  };
in
{
  options.services.claudeCodeManagedSettings = {
    enable = mkEnableOption ''
      /etc/claude-code/managed-settings.json — the four Claude Code settings
      keys the interactive harness must never be able to silently erase
      (status bar, clock hook, memory-index hook, spinner tips off)
    '';

    statuslineScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/statusline.sh";
      description = ''
        Path to the status-bar renderer. Lives on the soul volume, not the
        Nix store — see the module header's WORKS-BY-LUCK TRAP note: this
        path is invisible to tests/unit-script-refs.nix, so a missing file
        or a lost execute bit here fails silently at runtime, not at build.
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

    memoryIndexHookScript = mkOption {
      type = types.str;
      default = "/var/lib/sancta/.claude/index/bin/memory-index-hook";
      description = ''
        Path to the hook that keeps MEMORY.md derived from the memory files'
        frontmatter after every Write/Edit. Lives on the soul volume — same
        works-by-luck caveat as statuslineScript.
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
