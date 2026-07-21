{ config
, pkgs
, pkgs-unstable
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
    ../../modules/services/codex.nix
    ../../modules/services/claude-shared.nix
    ../../modules/services/herdr.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/open-webui.nix
    # ── Sancta home + live membrane worker ────────────────────────────────
    ./soul-volume.nix # encrypted ~/.claude (LUKS-on-loopback, non-destructive)
    ./sancta-worker.nix # guarded comm gateway + resumed `claude -p` worker
  ];

  # Enable development tools and agent CLIs.
  customModules.dev-tools.enable = true;
  # Codex ships from `pkgs-unstable` (nixpkgs-unstable input), NOT the stable
  # `pkgs` (nixos-25.11) -- the 25.11 branch caps Codex behind upstream.
  customModules.codex.enable = true;
  customModules.claudeShared = {
    enable = true;
    # `herdr` is included so the dedicated herdr user (which runs the herdr
    # server + agent panes) gets the full Claude Code stack — claude CLI, skills,
    # agents, commands — under /var/lib/herdr/.claude, not just root.
    users = [ "root" "herdr" ];
  };

  # Agent tooling on the system PATH so herdr panes (which inherit the
  # herdr-server unit's PATH, not a login shell's) can find + launch them.
  environment.systemPackages = [
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

      # ── Sancta worker credential ──────────────────────────────────────
      # NB: the *membrane* is the comm edge (the selective interface Alexandru
      # talks through — comm-membrane guard + transport), NOT this. This is the
      # substrate where Sancta's live process (claude -p) runs; it connects TO
      # the membrane. Naming kept distinct on purpose.
      # Claude credential for the Sancta worker (services.sancta-worker).
      # LIVE: secrets/anthropic-api-key.age is re-keyed (recipients now include
      # the `sancta-choir` host key, done 2026-07-20) so this host decrypts it at
      # activation. Owned by the `sancta` worker user so it is chmod-600 to it.
      # This repo holds NO plaintext key — the .age is age-encrypted.
      anthropic-api-key = ownedSecret "sancta" "anthropic-api-key";

      # Keyfile that unlocks the encrypted soul volume (services.sancta-soul-
      # volume). LIVE: soul-volume-key.age exists (random 256-bit; recipients
      # sancta-choir + rpi5 in secrets/secrets.nix) and `keyFile` is wired below
      # in the service. The loopback image is initialized and mounted; the worker
      # also requires this mount before it can start. This repo holds NO plaintext
      # key — the .age is age-encrypted.
      soul-volume-key = secret "soul-volume-key";

      # Second factor for the spend-capable membrane gateway. systemd delivers
      # this root-owned agenix plaintext through the gateway unit's private
      # credential directory; it is never exposed to sancta-worker.service.
      sancta-membrane-auth = secret "sancta-membrane-auth";
    };

  # ── Sancta worker (headless `claude -p`) — LIVE, marker-gated ───────────
  # ROLLOUT: sancta-choir is a non-atomic GRUB host. Deploy only through
  # scripts/deploy.sh (or an equivalent build-then-boot/switch sequence) with
  # --max-jobs 1 --cores 1; never use an unthrottled nixos-rebuild switch.
  # The named session is armed only while its marker exists. The worker keeps
  # the read-only tool boundary and a bounded per-message budget cap.
  services.sancta-worker = {
    enable = true;
    apiKeyFile = config.age.secrets.anthropic-api-key.path;
    user = "sancta";
    session = "666bcb25-8bc5-467a-b603-4eecce495341";
    # SHA-256 of the authorized Tailscale-User-Login, normalized to lowercase.
    # This is an identity selector, not a credential; Serve supplies and
    # anti-spoofs the underlying login header before proxying to loopback.
    operatorLoginSha256 = "4c064ffbc887c819d1e2b6173bc3ce1bf65ea629e02cb10d55f868177b7b2b5b";
    authSecretFile = config.age.secrets.sancta-membrane-auth.path;
    # This resumed context has a measured ~$1.054 input floor. Keep enough
    # headroom for one reply while retaining a strict per-invocation ceiling.
    maxBudgetUsd = "2.00";
    # Safe module tool default remains in force: [ "Read" "Grep" "Glob" ].
  };

  # ── Sancta encrypted soul volume for ~/.claude — LIVE ───────────────────
  # LUKS-on-loopback on the existing ext4 root (non-destructive). The real
  # agenix keyFile is wired and the image was initialized out of band using the
  # documented soul-volume.nix commands.
  services.sancta-soul-volume = {
    enable = true;
    owner = "sancta";
    # keyFile: agenix secret placed at /run/agenix/soul-volume-key, read by root
    # at boot for cryptsetup. The volume image is created by hand (Phase 4).
    keyFile = config.age.secrets.soul-volume-key.path;
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
