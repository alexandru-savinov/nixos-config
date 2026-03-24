{ pkgs
, lib
, config
, kuzea-ws
, ...
}:

let
  # kuzeaTranscribe: openai-whisper (Python) + ffmpeg (OGG/Opus -> WAV).
  # whisper-cpp 1.7.5 from nixpkgs segfaults on Skylake-IBRS VMs (backends=0);
  # openai-whisper is the working fallback. Model files cached in ~/.cache/whisper/.
  # Download: python3 -c "import whisper; whisper.load_model('base')"
  kuzeaTranscribe = pkgs.writeShellApplication {
    name = "kuzea-transcribe";
    runtimeInputs = [
      pkgs.ffmpeg
      (pkgs.python3.withPackages (ps: [ ps.openai-whisper ]))
    ];
    text = ''
      usage() {
        echo "Usage: kuzea-transcribe [--model MODEL] [--language LANG] <input-file>" >&2
        echo "  MODEL: tiny, base, small, medium, large (default: base)" >&2
        exit 1
      }

      MODEL="base"
      LANGUAGE_ARG=""
      INPUT_FILE=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --model) MODEL="$2"; shift 2 ;;
          --language) LANGUAGE_ARG="$2"; shift 2 ;;
          --help|-h) usage ;;
          -*) echo "Unknown option: $1" >&2; usage ;;
          *) INPUT_FILE="$1"; shift ;;
        esac
      done

      [[ -z "$INPUT_FILE" ]] && usage

      TMP_WAV=$(mktemp /tmp/whisper-XXXXXX.wav)
      trap 'rm -f "$TMP_WAV"' EXIT

      # -y and -loglevel are global ffmpeg options and must precede the first -i.
      # -loglevel error suppresses progress spam in the journal.
      ffmpeg -y -loglevel error -i "$INPUT_FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP_WAV"

      CACHE_DIR="''${WHISPER_CACHE_DIR:-$HOME/.cache/whisper}"

      python3 - "$TMP_WAV" "$MODEL" "$CACHE_DIR" "$LANGUAGE_ARG" << 'PYEOF'
      import sys, whisper

      wav_path, model_name, cache_dir, language = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
      model = whisper.load_model(model_name, download_root=cache_dir)
      opts = {}
      if language:
          opts["language"] = language
      result = model.transcribe(wav_path, **opts)
      print(result["text"].strip())
      PYEOF
    '';
  };

  # Chromium headless shell path from playwright-driver — shared by agentBrowser
  # and the openclawBrowserConfigScript below. Computed once to avoid duplication.
  chromiumRevision = pkgs.playwright-driver.browsersJSON."chromium-headless-shell".revision;
  chromiumBin = "${pkgs.playwright-driver.browsers}/chromium_headless_shell-${chromiumRevision}/chrome-linux/headless_shell";

  # agentBrowser: headless browser automation CLI for AI agents.
  # Rust CLI dispatches commands to a Node.js/Playwright daemon.
  # Uses nixpkgs playwright-driver.browsers — no runtime Chromium download.
  agentBrowser =
    let
      src = pkgs.fetchFromGitHub {
        owner = "vercel-labs";
        repo = "agent-browser";
        rev = "v0.14.0";
        hash = "sha256-oDgnxQ09e1IUd1kfgr75TNiYOf5VpMXG9DjfGG4OGwA=";
      };
      # Node.js daemon: TypeScript compiled to JS, uses playwright-core
      daemonDrv = pkgs.stdenv.mkDerivation {
        pname = "agent-browser-daemon";
        version = "0.14.0";
        inherit src;
        pnpmDeps = pkgs.pnpm.fetchDeps {
          pname = "agent-browser-daemon";
          version = "0.14.0";
          inherit src;
          # fetcherVersion required since nixpkgs 25.11; use 3 for reproducible tarballs.
          fetcherVersion = 3;
          hash = "sha256-ajlazaN9vdQ/d0g3DshHaHL0f4S8TsCi1P1sc3hEBgc=";
        };
        nativeBuildInputs = with pkgs; [
          nodejs_22
          pnpm.configHook
        ];
        buildPhase = "pnpm build";
        installPhase = ''
          mkdir -p $out
          # cp -rL would dereference pnpm virtual-store symlinks, breaking
          # transitive-dep resolution (Node.js traverses the real path, not the
          # .pnpm symlink chain). cp -r preserves relative symlinks so Node.js
          # still resolves packages through .pnpm/<pkg>/node_modules/<dep>/.
          cp -rL dist package.json $out/
          cp -r node_modules $out/
        '';
      };
      # Rust CLI: fast command dispatcher, spawns Node.js daemon on demand
      rustCli = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-browser-cli";
        version = "0.14.0";
        inherit src;
        cargoRoot = "cli";
        buildAndTestSubdir = "cli";
        cargoHash = "sha256-94w9V+NZiWeQ3WbQnsKxVxlvsCaOJR0Wm6XVc85Lo88=";
      };
    in
    # AGENT_BROWSER_EXECUTABLE_PATH bypasses playwright-core's revision check,
      # allowing the nixpkgs-provided Chromium to be used even when the npm package
      # revision differs. chromiumBin is defined in the outer let block.
    pkgs.stdenv.mkDerivation {
      pname = "agent-browser";
      version = "0.14.0";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      meta = {
        description = "Headless browser automation CLI for AI agents (Rust CLI + Playwright daemon)";
        homepage = "https://github.com/vercel-labs/agent-browser";
        license = lib.licenses.asl20;
        platforms = lib.platforms.linux;
        mainProgram = "agent-browser";
      };
      installPhase = ''
        mkdir -p $out/bin $out/share/agent-browser
        cp -r ${daemonDrv}/. $out/share/agent-browser/
        makeWrapper ${rustCli}/bin/agent-browser $out/bin/agent-browser \
          --set AGENT_BROWSER_HOME "$out/share/agent-browser" \
          --set AGENT_BROWSER_EXECUTABLE_PATH "${chromiumBin}" \
          --set PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS "true" \
          --prefix PATH : "${lib.makeBinPath [ pkgs.nodejs_22 ]}"
      '';
    };

  # Declarative browser config for OpenClaw: inject Chromium path (shared
  # chromiumBin binding above) into openclaw.json at service start.
  openclawBrowserConfigScript = pkgs.writeShellScript "openclaw-browser-config" ''
        ${pkgs.python3}/bin/python3 - <<'PYEOF'
    import json, os

    config_path = "/var/lib/openclaw/.openclaw/openclaw.json"

    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                config = json.load(f)
        except (json.JSONDecodeError, OSError):
            config = {}
    else:
        config = {}

    config["browser"] = {
        "enabled": True,
        "defaultProfile": "openclaw",
        "executablePath": "${chromiumBin}",
        "headless": True,
        # noSandbox is required: the openclaw user lacks CAP_SYS_ADMIN for
        # Chromium's user-namespace sandbox, and the setuid helper is not
        # available in the Nix store.  Defense-in-depth is provided by systemd
        # hardening (NoNewPrivileges, ProtectSystem=strict, PrivateDevices).
        "noSandbox": True,
    }

    # Ensure both sonnet and opus are in the allowed-models list so Kuzea
    # can switch to opus via /model or session_status without a manual edit.
    agents = config.setdefault("agents", {})
    defaults = agents.setdefault("defaults", {})
    models = defaults.setdefault("models", {})
    model = defaults.setdefault("model", {})
    model["primary"] = "anthropic/claude-opus-4-6"
    models.setdefault("anthropic/claude-sonnet-4-6", {})
    models.setdefault("anthropic/claude-opus-4-6", {})

    # Compaction: preserve 4 recent turns so Kuzea keeps conversational
    # context after auto-compaction instead of losing the thread.
    compaction = defaults.setdefault("compaction", {})
    compaction["mode"] = "safeguard"
    compaction["recentTurnsPreserve"] = 4

    # Enable self-improvement hook (agent:bootstrap reminder to log learnings).
    # Declarative equivalent of: openclaw hooks enable self-improvement
    hooks = config.setdefault("hooks", {})
    internal = hooks.setdefault("internal", {})
    internal["enabled"] = True
    entries = internal.setdefault("entries", {})
    entries.setdefault("self-improvement", {})["enabled"] = True

    # Enable Telegram streaming so partial replies appear in real-time
    channels = config.setdefault("channels", {})
    tg = channels.setdefault("telegram", {})
    tg["streaming"] = "partial"

    tmp = config_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.replace(tmp, config_path)
    PYEOF
  '';
in
{
  # Build tools for OpenClaw npm native compilation (llama.cpp, etc.)
  # Kept permanently for npm update -g openclaw recompilation
  environment.systemPackages = with pkgs; [
    cmake
    gnumake
    gcc
    python3
    nixd # Nix LSP for Claude Code (go-to-definition, NixOS options, diagnostics)
    vdirsyncer # CalDAV sync (used by caldav-calendar skill + briefing cron)
    khal # CLI calendar (reads vdirsyncer-synced .ics files)
    # openai-whisper available via kuzeaTranscribe runtimeInputs (not system-wide).
    # playwright-driver.browsers is a transitive closure dep of agentBrowser (via makeWrapper);
    # no need to list it here separately.
  ];

  # Pre-built Claude Code binaries from cachix (avoids building from source)
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://claude-code.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "claude-code.cachix.org-1:p3pMxGi7K+xT7I3dLghdlrUijD8s+wfQlmWp8gQ/TJA="
    ];
  };

  # ── OpenClaw User & Service ─────────────────────────────────────────────
  users.users.openclaw = {
    isSystemUser = true;
    group = "openclaw";
    home = "/var/lib/openclaw";
    createHome = true;
    # Shell for: sudo -u openclaw npm install/openclaw configure
    shell = pkgs.bash;
  };
  users.groups.openclaw = { };

  systemd.services.openclaw = {
    description = "OpenClaw AI Agent";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      HOME = "/var/lib/openclaw";
      # kuzeaTranscribe: openai-whisper + ffmpeg (OGG/Opus -> WAV) via runtimeInputs.
      # Model auto-downloads to ~/.cache/whisper/ (override with WHISPER_CACHE_DIR).
      PATH = lib.mkForce "/var/lib/openclaw/.npm-global/bin:${lib.makeBinPath (with pkgs; [ nodejs_22 git coreutils bash kuzeaTranscribe agentBrowser nixd vdirsyncer khal ])}:/run/current-system/sw/bin";
      # npm global prefix
      NPM_CONFIG_PREFIX = "/var/lib/openclaw/.npm-global";
      # Doctor recommendations: skip self-respawn and cache Node.js bytecode
      OPENCLAW_NO_RESPAWN = "1";
      NODE_COMPILE_CACHE = "/var/lib/openclaw/.node-compile-cache";
    };

    # ConditionPathExists prevents noisy restart loops if binary is missing
    # (must be in [Unit], not [Service] — systemd ignores it in [Service])
    unitConfig.ConditionPathExists = "/var/lib/openclaw/.npm-global/bin/openclaw";

    serviceConfig = {
      Type = "simple";
      User = "openclaw";
      Group = "openclaw";
      WorkingDirectory = "/var/lib/openclaw";
      # Inject Todoist and Airtable credentials from agenix secrets.
      # File format: KEY=value (one per line, no quotes needed).
      EnvironmentFile = [
        config.age.secrets.kuzea-todoist-credentials.path
        config.age.secrets.kuzea-airtable-credentials.path
        config.age.secrets.kuzea-tavily-api-key.path
      ];
      # Post-deploy setup (run once):
      #   sudo -u openclaw npm install -g openclaw
      #   sudo -u openclaw openclaw configure
      # Inject browser config + OpenAI auth for memory embeddings before start.
      ExecStartPre = [
        (pkgs.writeShellScript "openclaw-inject-openai-auth" ''
          set -euo pipefail
          AUTH_FILE="$HOME/.openclaw/agents/main/agent/auth-profiles.json"
          KEY="$(cat ${config.age.secrets.openai-api-key.path})"
          # Idempotent: add or update openai:manual profile in agent auth store.
          # Memory search uses this, not the OPENAI_API_KEY env var.
          # Note: key persists in auth-profiles.json (same as all openclaw auth).
          mkdir -p "$(dirname "$AUTH_FILE")"
          [ -f "$AUTH_FILE" ] || echo '{"profiles":{},"version":1}' > "$AUTH_FILE"
          ${pkgs.jq}/bin/jq --arg key "$KEY" \
            '.profiles["openai:manual"] = {"type": "token", "provider": "openai", "token": $key}' \
            "$AUTH_FILE" > "$AUTH_FILE.tmp" && mv "$AUTH_FILE.tmp" "$AUTH_FILE"
        '')
        (pkgs.writeShellScript "openclaw-setup-vdirsyncer" ''
                    set -euo pipefail
                    # Read CalDAV credentials from agenix secret (CALDAV_USER + CALDAV_PASSWORD)
                    CREDS="${config.age.secrets.kuzea-caldav-credentials.path}"
                    CALDAV_USER="$(grep '^CALDAV_USER=' "$CREDS" | cut -d= -f2-)"
                    CALDAV_PASSWORD="$(grep '^CALDAV_PASSWORD=' "$CREDS" | cut -d= -f2-)"

                    mkdir -p "$HOME/.config/vdirsyncer" "$HOME/.config/khal"
                    mkdir -p "$HOME/.local/share/vdirsyncer/calendar" "$HOME/.local/share/vdirsyncer/status"

                    # vdirsyncer config — syncs iCloud Family calendar to local .ics files
                    cat > "$HOME/.config/vdirsyncer/config" <<EOF
          [general]
          status_path = "~/.local/share/vdirsyncer/status/"

          [pair family_calendar]
          a = "family_calendar_remote"
          b = "family_calendar_local"
          collections = ["from a"]

          [storage family_calendar_remote]
          type = "caldav"
          url = "https://caldav.icloud.com/"
          username = "$CALDAV_USER"
          password = "$CALDAV_PASSWORD"

          [storage family_calendar_local]
          type = "filesystem"
          path = "~/.local/share/vdirsyncer/calendar/"
          fileext = ".ics"
          EOF
                    chmod 0600 "$HOME/.config/vdirsyncer/config"

                    # khal config — reads synced .ics files (type=discover auto-finds all calendars)
                    cat > "$HOME/.config/khal/config" <<EOF
          [calendars]
          [[all]]
          path = ~/.local/share/vdirsyncer/calendar/*
          type = discover

          [locale]
          timeformat = %H:%M
          dateformat = %Y-%m-%d
          longdateformat = %Y-%m-%d
          datetimeformat = %Y-%m-%d %H:%M
          longdatetimeformat = %Y-%m-%d %H:%M
          EOF

                    # Initial sync (discover + sync) — non-fatal if network unavailable
                    yes | ${pkgs.vdirsyncer}/bin/vdirsyncer discover || true
                    ${pkgs.vdirsyncer}/bin/vdirsyncer sync || true
        '')
        openclawBrowserConfigScript
      ];
      ExecStart = "/var/lib/openclaw/.npm-global/bin/openclaw gateway --port 18789";
      Restart = "on-failure";
      RestartSec = 10;

      # Resource limits: 6GB memory, 300% CPU (3 of 4 cores)
      MemoryMax = "6G";
      MemoryHigh = "5G";
      CPUQuota = "300%";

      # Hardening (no MemoryDenyWriteExecute — Node.js needs JIT)
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true; # /var/lib/openclaw is not under /home
      PrivateDevices = true;
      # /dev/shm is required by Chromium (renderer <-> browser IPC).
      # PrivateDevices creates a minimal /dev without /dev/shm, so we bind it
      # explicitly. The host's /dev/shm tmpfs is mounted read-write in the
      # private namespace; no other devices are exposed.
      BindPaths = [ "/dev/shm" ];
      ReadWritePaths = [ "/var/lib/openclaw" ];
      PrivateTmp = true;
    };
  };

  # ── Declarative runtime files (openclaw user) ──────────────────────────
  # These files were previously created imperatively and would be lost on
  # rebuild. tmpfiles L+ creates forced symlinks into the nix store.
  # Todoist skill directory is built as a derivation and symlinked whole.
  systemd.tmpfiles.rules = [
    # Home dir must be group-readable (0750) so backup-pull user
    # (member of openclaw group) can rsync via rrsync.
    "d /var/lib/openclaw 0750 openclaw openclaw -"
    # Default ACL: new files/dirs inherit group-read for backup-pull.
    # 'a+' = set ACL without changing owner/mode; 'd:' = default (inherited).
    "a+ /var/lib/openclaw - - - - d:group:openclaw:r-X"
    "a+ /var/lib/openclaw - - - - group:openclaw:r-x"
    "d /var/lib/openclaw/bin 0755 openclaw openclaw -"
    "d /var/lib/openclaw/.claude 0700 openclaw openclaw -"
    # vdirsyncer + khal data dirs (ExecStartPre creates config files at runtime)
    "d /var/lib/openclaw/.local 0700 openclaw openclaw -"
    "d /var/lib/openclaw/.local/share 0700 openclaw openclaw -"
    "d /var/lib/openclaw/.local/share/vdirsyncer 0700 openclaw openclaw -"
    # Node.js bytecode cache — doctor recommendation for faster CLI on VPS
    "d /var/lib/openclaw/.node-compile-cache 0700 openclaw openclaw -"
    # Ensure parent directories exist before creating the skills symlink.
    # systemd-tmpfiles does not auto-create missing intermediate parents.
    "d /var/lib/openclaw/.openclaw 0755 openclaw openclaw -"
    "d /var/lib/openclaw/.openclaw/workspace 0755 openclaw openclaw -"
    "d /var/lib/openclaw/.openclaw/workspace/skills 0755 openclaw openclaw -"
    "d /var/lib/openclaw/.openclaw/workspace/hooks 0755 openclaw openclaw -"
    # Managed hooks dir — scanned by OpenClaw at startup (openclaw-managed source).
    # Must be a real directory, not a symlink: Node.js Dirent.isDirectory() does
    # not follow symlinks, so openclaw would silently skip symlinked hook dirs.
    "d /var/lib/openclaw/.openclaw/hooks 0755 openclaw openclaw -"
    # writeTextFile with executable=true sets 0555 on the nix store file so the
    # resulting symlink is directly executable (node cron-manage.mjs).
    "L+ /var/lib/openclaw/bin/cron-manage.mjs - - - - ${kuzea-ws.cron-manage}"
    # Source file is claude-CLAUDE.md to avoid the dot-prefix in the repo;
    # deployed as .claude/CLAUDE.md (the path Claude Code reads on startup).
    "L+ /var/lib/openclaw/.claude/CLAUDE.md - - - - ${kuzea-ws.claude-md}"
    # skipDangerousModePermissionPrompt is intentional: the openclaw user runs
    # under NoNewPrivileges=true with no sudo access, so Claude Code cannot
    # escalate privileges even with prompts disabled.
    # C (copy-if-missing) instead of L+ (symlink) so Claude Code plugins can
    # write to settings.json at runtime. Seeds base settings on first deploy;
    # subsequent rebuilds preserve runtime modifications (enabledPlugins etc.).
    # To force-reset: delete the file and run `systemd-tmpfiles --create`.
    "C /var/lib/openclaw/.claude/settings.json 0644 openclaw openclaw - ${kuzea-ws.claude-settings}"
    # TODOIST_API_KEY is injected via EnvironmentFile from the agenix secret
    # kuzea-todoist-credentials (PR #297). Skill is fully operational post-rebuild.
    "L+ /var/lib/openclaw/.openclaw/workspace/skills/todoist-natural-language - - - - ${kuzea-ws.skills-todoist-natural-language}"
    # Self-Improving Agent skill (pskoett/self-improving-agent v1.0.11).
    # Logs errors, corrections, and feature requests to .learnings/ for continuous
    # improvement. Hook injects a reminder at agent:bootstrap to capture learnings.
    "L+ /var/lib/openclaw/.openclaw/workspace/skills/self-improving-agent - - - - ${kuzea-ws.skills-self-improving-agent}"
    # Agent Browser CLI reference (vercel-labs/agent-browser) — complete command docs
    # so Kuzea always has the full snapshot/click/fill/record reference available.
    "L+ /var/lib/openclaw/.openclaw/workspace/skills/agent-browser - - - - ${kuzea-ws.skills-agent-browser}"
    # Claude Code agent-teams & subagents reference — documents custom subagent
    # creation, agent file locations, and experimental agent teams for parallel work.
    "L+ /var/lib/openclaw/.openclaw/workspace/skills/claude-code-agents - - - - ${kuzea-ws.skills-claude-code-agents}"
    # Local overrides for coding-agent skill — documents --output-format text fix
    # so Claude Code -p output is captured by OpenClaw's PTY process manager.
    "L+ /var/lib/openclaw/.openclaw/workspace/skills/coding-agent-local - - - - ${kuzea-ws.skills-coding-agent-local}"
    # Hook goes into the managed dir (.openclaw/hooks/), NOT workspace/hooks/.
    # Reason: openclaw scans hooks via Node.js readdirSync + Dirent.isDirectory(),
    # which returns false for symlinks-to-directories. Using C+ creates real files
    # that pass the isDirectory() check and are picked up as "openclaw-managed".
    # workspace/hooks/ symlink is intentionally omitted: it was non-functional and
    # only created confusion. .openclaw/hooks/ is the canonical location used by
    # `openclaw hooks install` and loadHookEntries(managedHooksDir).
    "C+ /var/lib/openclaw/.openclaw/hooks/self-improvement - openclaw openclaw - ${kuzea-ws.hooks-self-improvement}"
    # .learnings/ is mutable state (grows over time) — created writable, never
    # symlinked to the Nix store. `f` creates the file only if it doesn't exist,
    # preserving accumulated learnings across rebuilds.
    "d /var/lib/openclaw/.openclaw/workspace/.learnings 0700 openclaw openclaw -"
  ]
  ++ map (f: "f /var/lib/openclaw/.openclaw/workspace/.learnings/${f} 0600 openclaw openclaw -") [
    "LEARNINGS.md"
    "ERRORS.md"
    "FEATURE_REQUESTS.md"
  ]
  ++ [
    # GitHub credential helper: reads PAT from /run/agenix/kuzea-github-token at
    # runtime so the token is never stored in plaintext on disk.
    # Replaces the former ~/.git-credentials store helper approach.
    # writeShellScript patches the shebang to the nix store bash automatically.
    "L+ /var/lib/openclaw/bin/git-credential-agenix - - - - ${kuzea-ws.git-credential-agenix}"
    # .gitconfig is managed declaratively so the credential helper path always
    # points to the nix-store copy. The file is read-only by intent; use
    # nixos-config to make config changes rather than git config --global.
    "L+ /var/lib/openclaw/.gitconfig - - - - ${kuzea-ws.gitconfig}"
    # Remove legacy plaintext credential files left over from the pre-agenix
    # setup. 'r' removes the file if it exists; safe to leave in perpetually.
    "r /var/lib/openclaw/.git-credentials - - - -"
    "r /var/lib/openclaw/.git-credentials.bak - - - -"
  ];
}
