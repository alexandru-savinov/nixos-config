{ config
, pkgs
, lib
, self
, ...
}:

{
  # Pin kernel to 6.6 LTS — workaround for the Feb-2026 #252 incident, where an
  # OOM-killed build left corrupted 6.12.63 store paths that would not boot. The
  # 6.12 kernel itself is not broken; the corruption was build-time only.
  # EXIT CRITERIA (unpin only when ALL hold): (1) GC the corrupt paths on-host
  # (`nix-collect-garbage -d`); (2) a clean `nixos-rebuild build` of a 6.12 kernel
  # succeeds on-host; (3) validate via `nixos-rebuild boot` + manual reboot first.
  # Do NOT unpin remotely-untested — a bad kernel on a headless VPS needs
  # rescue-mode recovery.
  boot.kernelPackages = pkgs.linuxPackages_6_6;

  # Enable aarch64 emulation for cross-building RPi5 images
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Add nix-community cache for pre-built RPi5 kernels
  # Also add claude-code cachix for pre-built Claude Code binaries
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://claude-code.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "claude-code.cachix.org-1:p3pMxGi7K+xT7I3dLghdlrUijD8s+wfQlmWp8gQ/TJA="
    ];
  };

  imports = [
    ./hardware-configuration.nix
    ./networking.nix
    ../common.nix
    ../../modules/system/dev-tools.nix
    ../../modules/users/root.nix
    ../../modules/services/claude-shared.nix
    ../../modules/services/herdr.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/open-webui.nix
  ];

  # Enable development tools and Claude Code
  customModules.dev-tools.enable = true;
  customModules.claudeShared = {
    enable = true;
    # `herdr` is included so the dedicated herdr user (which runs the herdr
    # server + agent panes) gets the full Claude Code stack — claude CLI, skills,
    # agents, commands — under /var/lib/herdr/.claude, not just root.
    users = [ "root" "herdr" ];
  };

  # Agent tooling on the system PATH so herdr panes (which inherit the
  # herdr-server unit's PATH, not a login shell's) can find + launch them:
  # OpenAI Codex CLI (github.com/openai/codex) as a second coding agent
  # alongside Claude Code, plus git + curl that the agents and herdr need.
  environment.systemPackages = [
    pkgs.codex
    pkgs.git
    pkgs.curl
    # ralphex — multi-step Claude Code plan orchestrator (umputun/ralphex,
    # packaged in pkgs/ralphex.nix). Activates the `ralphex` + `brainstorming`
    # claude-shared skills on this host (the latter hands off to `ralphex`).
    # Mirrors rpi5-full; sancta-choir is the always-on agent host.
    self.packages.${pkgs.system}.ralphex

    # `hermes-claw` — full SSH login from the unprivileged `herdr` user to
    # hermes-claw (root), so a herdr pane can drive the Hermes agent (Nous
    # Research) that runs in the `hermes-agent` Podman container over there.
    # The Hermes gateway, its sessions, memory and workspace all live INSIDE
    # that container (HERMES_HOME=/data/.hermes), so an interactive session
    # must run there too — the wrapper opens a root shell on hermes-claw; to
    # jump straight into a live Hermes session co-located with the agent, run:
    #   hermes-claw podman exec -it hermes-agent hermes chat
    # Key: agenix `herdr-hermes-ssh-key` (private), whose public half is in
    # hosts/hermes-claw root authorizedKeys. Reaches the box over Tailscale.
    (pkgs.writeShellScriptBin "hermes-claw" ''
      exec ${pkgs.openssh}/bin/ssh -t \
        -i ${config.age.secrets.herdr-hermes-ssh-key.path} \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/var/lib/herdr/.ssh/known_hosts \
        root@hermes-claw.tail4249a9.ts.net "$@"
    '')
  ];

  # Writable known_hosts dir for the herdr user so the `hermes-claw` wrapper's
  # `accept-new` can persist hermes-claw's host key across connections (the
  # herdr-server unit and its panes run as `herdr` with HOME=/var/lib/herdr).
  systemd.tmpfiles.rules = [
    "d /var/lib/herdr/.ssh 0700 herdr herdr -"
  ];

  # home-manager rewrites herdr's ~/.claude/settings.json on EVERY activation,
  # which clobbers the claude agent-state hook that `herdr integration install`
  # wires into it — and a no-change `nixos-rebuild switch` re-runs HM but does
  # NOT restart herdr-server, so its ExecStartPost wouldn't re-add the hook.
  # Re-install both integrations at the END of herdr's HM activation (after the
  # settings file is written), so the hook is present after every deploy, even
  # no-change ones. (codex stores its hook in its own hooks.json, which HM does
  # not touch, but we re-run it too for symmetry/idempotence.)
  home-manager.users.herdr = { lib, ... }: {
    home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="/etc/profiles/per-user/herdr/bin:/run/current-system/sw/bin:$PATH"
      herdr integration install claude || true
      herdr integration install codex || true
    '';
  };

  # herdr — always-on terminal workspace server for AI coding agents. The server
  # lives here so long-running sessions survive the Mac sleeping; it runs as a
  # dedicated unprivileged `herdr` user whose only sudo is a fixed-flake deploy
  # wrapper (`herdr-deploy`) + GC — no raw nixos-rebuild/systemctl. Attach with
  # `herdr --remote herdr@sancta-choir-1.tail4249a9.ts.net`.
  customModules.herdr.enable = true;

  # Agenix secrets (defaults: owner=root, group=root, mode=0400)
  age.secrets =
    let
      inherit (import ../../lib/secrets.nix { inherit self; }) secret ownedSecret;
    in
    {
      tailscale-auth-key = secret "tailscale-auth-key";
      # Open-WebUI secrets
      open-webui-secret-key = secret "open-webui-secret-key";
      openrouter-api-key = secret "openrouter-api-key";
      tavily-api-key = secret "tavily-api-key";
      e2e-test-api-key = secret "e2e-test-api-key";
      # SSH private key for the herdr user → hermes-claw (the `hermes-claw`
      # wrapper above). owner=herdr so the unprivileged server/panes can read
      # it; public half lives in hosts/hermes-claw root authorizedKeys.
      herdr-hermes-ssh-key = ownedSecret "herdr" "herdr-hermes-ssh-key";
    };

  # ==========================================================================
  # Open-WebUI — AI chat gateway via OpenRouter
  # ==========================================================================
  # Access: https://sancta-choir-1.tail4249a9.ts.net (via Tailscale Serve)
  services.open-webui-tailscale = {
    enable = true;
    webuiUrl = "https://sancta-choir-1.tail4249a9.ts.net";
    secretKeyFile = config.age.secrets.open-webui-secret-key.path;

    # OpenRouter as LLM backend
    openai.apiKeyFile = config.age.secrets.openrouter-api-key.path;

    # OIDC via Tailscale tsidp
    oidc.enable = true;

    # Tavily web search
    tavilySearch = {
      enable = true;
      apiKeyFile = config.age.secrets.tavily-api-key.path;
    };

    # Memory features
    memory.enable = true;
    autoMemory.enable = true;

    # ZDR-only models (OpenRouter Zero Data Retention)
    zdrModelsOnly.enable = true;

    # OpenRouter cost tracking (per-request cost + credits remaining)
    costTracker.enable = true;

    # E2E testing
    testing = {
      enable = true;
      apiKeyFile = config.age.secrets.e2e-test-api-key.path;
    };

    # Tailscale Serve HTTPS (default: enabled on port 443)
    tailscaleServe.enable = true;
  };

  # Home Manager (root user config provided by modules/users/root.nix)
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
  };

  # Swap space (4GB for Open-WebUI + builds on 8GB VPS)
  swapDevices = [
    {
      device = "/swapfile";
      size = 4096; # 4GB
    }
  ];

  networking.hostName = "sancta-choir";

  # SSH authorized keys for remote access
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2btaYomBlcKG+snrIrBuTXcEaBKEGQoAaF59YWwkal nixos@rpi5"
  ];

  # Fresh install — NixOS 25.05
  system.stateVersion = "25.05";
}
