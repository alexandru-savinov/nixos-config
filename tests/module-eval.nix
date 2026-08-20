# Module evaluation tests — verify NixOS modules evaluate correctly
# without needing to build derivations or spin up VMs.
#
# These tests catch:
#   - Import errors (typos, missing files)
#   - Type mismatches (wrong option types)
#   - Broken assertions (security checks, dependency validation)
#   - Incorrect mkIf conditional logic
#
# How it works:
#   Each test evaluates a minimal NixOS config that imports one module,
#   enables it with the minimum required options, and forces evaluation
#   of config.system.build.toplevel.drvPath. This resolves all module
#   system merging without actually building anything.
#
# Run: nix build .#checks.<system>.module-eval
#
# Called from flake.nix with: { pkgs, nixpkgs, self }

{ pkgs
, nixpkgs
, self
,
}:

let
  system = pkgs.system;

  # Evaluate a NixOS config with the given modules and specialArgs.
  # Returns the fully-merged config attrset.
  evalConfig =
    { modules
    , specialArgs ? { }
    ,
    }:
    (nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit self;
      }
      // specialArgs;
      modules = [
        # Minimal base so the module system doesn't complain about
        # missing boot.loader / fileSystems / etc.
        (
          { lib, ... }:
          {
            boot.loader.grub.enable = lib.mkDefault false;
            fileSystems."/" = lib.mkDefault {
              device = "/dev/sda1";
              fsType = "ext4";
            };
            system.stateVersion = lib.mkDefault "25.11";
            nixpkgs.hostPlatform = lib.mkDefault system;
            nixpkgs.config.allowUnfree = true;
          }
        )
      ]
      ++ modules;
    }).config;

  # Force-evaluate a config down to its toplevel derivation path.
  # This triggers all assertions and option merging.
  forceEval = config: builtins.seq config.system.build.toplevel.drvPath true;

  # Check that evaluation succeeds (module is valid with given config).
  # Does NOT wrap with tryEval — if evaluation fails, the raw Nix error
  # propagates with full context (option path, assertion message, etc.).
  shouldEval =
    name: args:
    let
      config = evalConfig args;
    in
    builtins.addErrorContext "in test '${name}'" (forceEval config);

  # Check that evaluation fails (assertion should fire for bad config).
  shouldFail =
    name: args:
    let
      config = evalConfig args;
      result = builtins.tryEval (forceEval config);
    in
    if !result.success then
      true
    else
      builtins.throw "FAIL: ${name} — expected assertion failure but evaluation succeeded";

  # ── Test definitions ──────────────────────────────────────────────

  tests = {

    # ── Qdrant ────────────────────────────────────────────────────
    qdrant-minimal = shouldEval "qdrant: minimal config" {
      modules = [
        ../modules/services/qdrant.nix
        {
          services.qdrant-tailscale.enable = true;
          services.qdrant-tailscale.tailscaleServe.enable = false;
        }
      ];
    };

    qdrant-on-disk = shouldEval "qdrant: on-disk storage" {
      modules = [
        ../modules/services/qdrant.nix
        {
          services.qdrant-tailscale.enable = true;
          services.qdrant-tailscale.storage.onDisk = true;
          services.qdrant-tailscale.tailscaleServe.enable = false;
        }
      ];
    };

    qdrant-disabled = shouldEval "qdrant: disabled" {
      modules = [
        ../modules/services/qdrant.nix
        { services.qdrant-tailscale.enable = false; }
      ];
    };

    # ── Gatus ─────────────────────────────────────────────────────
    gatus-minimal = shouldEval "gatus: minimal config" {
      modules = [
        ../modules/services/gatus.nix
        {
          services.gatus-tailscale.enable = true;
          services.gatus-tailscale.tailscaleServe.enable = false;
        }
      ];
    };

    gatus-with-endpoint = shouldEval "gatus: with endpoint" {
      modules = [
        ../modules/services/gatus.nix
        {
          services.gatus-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            endpoints = {
              test-health = {
                name = "Test Health";
                url = "http://127.0.0.1:8080/health";
                interval = "60s";
                conditions = [ "[STATUS] == 200" ];
              };
            };
          };
        }
      ];
    };

    gatus-with-suite = shouldEval "gatus: with suite" {
      modules = [
        ../modules/services/gatus.nix
        {
          services.gatus-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            suites = {
              test-suite = {
                name = "Test Suite";
                endpoints = [
                  {
                    name = "step-1";
                    url = "http://127.0.0.1:8080/api/test";
                    conditions = [ "[STATUS] == 200" ];
                    store = {
                      response_id = "[BODY].id";
                    };
                  }
                  {
                    name = "step-2";
                    url = "http://127.0.0.1:8080/api/test/[CONTEXT].response_id";
                    conditions = [ "[STATUS] == 200" ];
                  }
                ];
              };
            };
          };
        }
      ];
    };

    gatus-disabled = shouldEval "gatus: disabled" {
      modules = [
        ../modules/services/gatus.nix
        { services.gatus-tailscale.enable = false; }
      ];
    };

    # ── NixFrame ──────────────────────────────────────────────────
    nixframe-minimal = shouldEval "nixframe: minimal config" {
      modules = [
        ../modules/services/nixframe.nix
        { services.nixframe.enable = true; }
      ];
    };

    nixframe-with-weather = shouldEval "nixframe: with weather" {
      modules = [
        ../modules/services/nixframe.nix
        {
          services.nixframe = {
            enable = true;
            weather.enable = true;
          };
        }
      ];
    };

    nixframe-with-calendar = shouldEval "nixframe: with calendar" {
      modules = [
        ../modules/services/nixframe.nix
        {
          services.nixframe = {
            enable = true;
            calendar.enable = true;
            calendar.credentialsFile = "/run/secrets/caldav";
          };
        }
      ];
    };

    nixframe-disabled = shouldEval "nixframe: disabled" {
      modules = [
        ../modules/services/nixframe.nix
        { services.nixframe.enable = false; }
      ];
    };

    # ── Backup-pull ───────────────────────────────────────────────
    backup-pull-minimal = shouldEval "backup-pull: minimal config" {
      modules = [
        ../modules/services/backup-pull.nix
        {
          services.backup-pull = {
            enable = true;
            remoteHost = "test-host";
            remotePaths = [ "/var/lib/data" ];
            sshKeyFile = "/run/secrets/ssh-key";
            resticPasswordFile = "/run/secrets/restic-pw";
          };
        }
      ];
    };

    backup-pull-disabled = shouldEval "backup-pull: disabled" {
      modules = [
        ../modules/services/backup-pull.nix
        { services.backup-pull.enable = false; }
      ];
    };

    # ── n8n ───────────────────────────────────────────────────────
    n8n-minimal = shouldEval "n8n: minimal config" {
      modules = [
        ../modules/services/n8n.nix
        {
          services.n8n-tailscale = {
            enable = true;
            encryptionKeyFile = "/run/secrets/n8n-encryption-key";
            tailscaleServe.enable = false;
          };
        }
      ];
    };

    n8n-missing-encryption-key-rejected = shouldFail "n8n: missing encryption key rejected" {
      modules = [
        ../modules/services/n8n.nix
        {
          services.n8n-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            # encryptionKeyFile intentionally omitted — assertion should fire
          };
        }
      ];
    };

    n8n-with-encryption-key = shouldEval "n8n: with encryption key" {
      modules = [
        ../modules/services/n8n.nix
        {
          services.n8n-tailscale = {
            enable = true;
            encryptionKeyFile = "/run/secrets/n8n-encryption-key";
            tailscaleServe.enable = false;
          };
        }
      ];
    };

    n8n-nix-store-secret-rejected = shouldFail "n8n: nix-store secret rejected" {
      modules = [
        ../modules/services/n8n.nix
        {
          services.n8n-tailscale = {
            enable = true;
            encryptionKeyFile = "/nix/store/fake-hash-secret";
            tailscaleServe.enable = false;
          };
        }
      ];
    };

    n8n-disabled = shouldEval "n8n: disabled" {
      modules = [
        ../modules/services/n8n.nix
        { services.n8n-tailscale.enable = false; }
      ];
    };

    # ── Open-WebUI ────────────────────────────────────────────────
    open-webui-minimal = shouldEval "open-webui: minimal config" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            secretKeyFile = "/run/secrets/webui-secret";
            tailscaleServe.enable = false;
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    open-webui-missing-secret-key-rejected = shouldFail "open-webui: missing secret key rejected" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            # secretKeyFile intentionally omitted — assertion should fire
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    open-webui-with-testing = shouldEval "open-webui: with testing enabled" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            testing.enable = true;
            testing.apiKeyFile = "/run/secrets/e2e-key";
            secretKeyFile = "/run/secrets/webui-secret";
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    open-webui-testing-requires-secret-key = shouldFail "open-webui: testing without secretKeyFile" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            testing.enable = true;
            testing.apiKeyFile = "/run/secrets/e2e-key";
            # secretKeyFile intentionally omitted — assertion should fire
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    open-webui-auto-memory-requires-memory = shouldFail "open-webui: autoMemory without memory" {
      modules = [
        ../modules/services/open-webui.nix
        {
          services.open-webui-tailscale = {
            enable = true;
            tailscaleServe.enable = false;
            autoMemory.enable = true;
            memory.enable = false;
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    open-webui-disabled = shouldEval "open-webui: disabled" {
      modules = [
        ../modules/services/open-webui.nix
        { services.open-webui-tailscale.enable = false; }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    # ── OpenClaw ──────────────────────────────────────────────────
    openclaw-missing-claude-code = shouldFail "openclaw: missing claude-code input" {
      modules = [
        ../modules/services/openclaw.nix
        {
          services.openclaw = {
            enable = true;
            anthropicApiKeyFile = "/run/secrets/anthropic-key";
            githubTokenFile = "/run/secrets/github-token";
          };
        }
      ];
      # claude-code intentionally omitted — assertion should fire
      specialArgs = {
        claude-code = null;
      };
    };

    openclaw-nix-store-secret-rejected = shouldFail "openclaw: nix-store secret rejected" {
      modules = [
        ../modules/services/openclaw.nix
        {
          services.openclaw = {
            enable = true;
            anthropicApiKeyFile = "/nix/store/fake-hash-secret";
            githubTokenFile = "/run/secrets/github-token";
          };
        }
      ];
      # Provide a mock claude-code so the null-input assertion doesn't fire;
      # we're testing ONLY the /nix/store secret assertion here.
      specialArgs = {
        claude-code = {
          packages.${system}.default = pkgs.hello;
        };
      };
    };

    openclaw-disabled = shouldEval "openclaw: disabled" {
      modules = [
        ../modules/services/openclaw.nix
        { services.openclaw.enable = false; }
      ];
      specialArgs = {
        claude-code = null;
      };
    };

    # ── NullClaw ──────────────────────────────────────────────────
    nullclaw-minimal = shouldEval "nullclaw: minimal config" {
      modules = [
        ../modules/services/nullclaw.nix
        {
          services.nullclaw = {
            enable = true;
            apiKeyFile = "/run/secrets/anthropic-key";
            # telegram.enable defaults to true, requiring botTokenFile;
            # disable it for the minimal-config test.
            telegram.enable = false;
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    nullclaw-nix-store-secret-rejected = shouldFail "nullclaw: nix-store api key rejected" {
      modules = [
        ../modules/services/nullclaw.nix
        {
          services.nullclaw = {
            enable = true;
            apiKeyFile = "/nix/store/fake-hash-key";
            # Disable telegram so only the /nix/store assertion fires,
            # not the missing botTokenFile error.
            telegram.enable = false;
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    nullclaw-telegram-nix-store-rejected = shouldFail "nullclaw: nix-store telegram token rejected" {
      modules = [
        ../modules/services/nullclaw.nix
        {
          services.nullclaw = {
            enable = true;
            apiKeyFile = "/run/secrets/anthropic-key";
            telegram.enable = true;
            telegram.botTokenFile = "/nix/store/fake-hash-token";
            telegram.allowedUsers = [ "12345" ];
          };
        }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    nullclaw-disabled = shouldEval "nullclaw: disabled" {
      modules = [
        ../modules/services/nullclaw.nix
        { services.nullclaw.enable = false; }
      ];
      specialArgs = {
        pkgs-unstable = pkgs;
      };
    };

    # nullclaw-injection-key-paths / nullclaw-injection-guard-fires: retired
    # 2026-08-20 with zero-kuzea, the only host that ever built
    # nullclawConfigInjection (see docs/retired.md). The module-level tests
    # above (nullclaw-minimal, nullclaw-disabled, etc.) still guard the
    # OPTION SURFACE of modules/services/nullclaw.nix in isolation — but with
    # zero-kuzea gone, no host imports this module anymore, so nothing here
    # actually exercises the real injection contract (nullclawConfigInjection
    # against a live nullclaw binary) end to end. That coverage is gone, not
    # "unaffected" — it only comes back if/when a host imports nullclaw.nix
    # again.

    # ── UniFi MCP ─────────────────────────────────────────────────
    unifi-mcp-minimal = shouldEval "unifi-mcp: minimal config" {
      modules = [
        ../modules/services/unifi-mcp.nix
        {
          services.unifi-mcp = {
            enable = true;
            host = "192.168.1.1";
            passwordFile = "/run/secrets/unifi-password";
          };
        }
      ];
    };

    unifi-mcp-disabled = shouldEval "unifi-mcp: disabled" {
      modules = [
        ../modules/services/unifi-mcp.nix
        { services.unifi-mcp.enable = false; }
      ];
    };

    # ── Sancta Gallery: the tailnet bind must not race tailscaled ──
    #
    # The own-origin shape binds a Tailscale address, which tailscaled assigns
    # after it starts. `After=network.target` says nothing about that, so on
    # 2026-07-30 the deployed unit could bind() before the address existed, get
    # EADDRNOTAVAIL, burn Restart=always/startLimitBurst in ~25s and stay
    # permanently failed. Assert the ordering AND the probe on the real host
    # config, so the fix cannot be silently dropped by a later refactor.
    sancta-gallery-choir-waits-for-tailscaled =
      let
        svc = self.nixosConfigurations.sancta-choir.config.systemd.services.sancta-gallery;
        checks = {
          bindIsTailnet = nixpkgs.lib.hasPrefix "100." svc.environment.GALLERY_BIND;
          orderedAfterTailscaled = builtins.elem "tailscaled.service" svc.after;
          wantsTailscaled = builtins.elem "tailscaled.service" svc.wants;
          # Ordering alone is not enough: tailscaled can be active before the
          # address is assigned, so the unit must also wait on the bind itself.
          hasBindProbe = (svc.serviceConfig.ExecStartPre or null) != null;
          # The probe may spend 60s; the 90s systemd default would SIGTERM it.
          timeoutRaised = (svc.serviceConfig.TimeoutStartSec or 90) >= 120;

          # The rate-limit window must hold `startLimitBurst + 1` attempts, not
          # just `startLimitBurst`. systemd resets the window when
          # `begin + interval < now` (STRICT), and one attempt actually costs a
          # little MORE than the nominal `probe wait + RestartSec` (the probe's
          # deadline loop overshoots the last second, plus restart scheduling).
          # A window of exactly `burst * cost` therefore lets the (burst+1)-th
          # start land just past the boundary, where systemd RESETS the counter
          # instead of denying it — the count never reaches the burst, the unit
          # never enters `failed`, and OnFailure never fires: it retries forever,
          # silently. The first fix on #554 used `>= cost * burst` and was STILL
          # on the wrong side of that boundary; two reviewers flagged it. `+ 1`
          # attempt of headroom absorbs the overshoot. This assertion ties the
          # numbers together so the next edit to any one fails CI, not prod.
          startLimitWindowExhaustible =
            let
              attemptCost = 60 + svc.serviceConfig.RestartSec; # probe wait + backoff
            in
            svc.startLimitIntervalSec >= attemptCost * (svc.startLimitBurst + 1);
        };
        failed = builtins.filter (name: !checks.${name}) (builtins.attrNames checks);
      in
      if failed == [ ] then
        true
      else
        builtins.throw "FAIL: sancta-choir sancta-gallery would race tailscaled at boot — failed checks: ${builtins.toJSON failed}";

    # Negative control for the branch above: the loopback shape must NOT pull in
    # tailscaled or the probe. Without this, making the ordering unconditional
    # would pass the test above while adding a dangling dependency on every host
    # that uses the loopback shape — a check that cannot fail.
    sancta-gallery-loopback-has-no-tailscaled-dep =
      let
        config = evalConfig {
          modules = [
            ../modules/services/sancta-gallery.nix
            {
              services.sancta-gallery.enable = true;
              # bind defaults to 127.0.0.1 — the loopback shape.
              users.users.nixos = {
                isNormalUser = true;
                group = "users";
              };
            }
          ];
        };
        svc = config.systemd.services.sancta-gallery;
        leaked = builtins.elem "tailscaled.service" (svc.after ++ svc.wants);
        probed = (svc.serviceConfig.ExecStartPre or null) != null;
      in
      if !leaked && !probed then
        true
      else
        builtins.throw "FAIL: sancta-gallery loopback shape gained tailnet-only wiring (tailscaled dep: ${builtins.toJSON leaked}, bind probe: ${builtins.toJSON probed}) — the own-origin branch is not actually conditional.";

    # ── Claude module ─────────────────────────────────────────────
    claude-missing-input = shouldFail "claude: missing claude-code input" {
      modules = [
        ../modules/services/claude.nix
        { customModules.claude.enable = true; }
      ];
      specialArgs = {
        claude-code = null;
      };
    };

    claude-disabled = shouldEval "claude: disabled" {
      modules = [
        ../modules/services/claude.nix
        { customModules.claude.enable = false; }
      ];
      specialArgs = {
        claude-code = null;
      };
    };

    # ── OpenClaw ZDR Proxy ────────────────────────────────────────
    openclaw-zdr-proxy-minimal = shouldEval "openclaw-zdr-proxy: minimal config" {
      modules = [
        ../modules/services/openclaw-zdr-proxy.nix
        {
          services.openclaw-zdr-proxy = {
            enable = true;
            apiKeyFile = "/run/agenix/openrouter-api-key";
          };
          # The proxy unit runs as user `openclaw`, normally created by
          # the host-level openclaw service. Declare it here so the
          # isolated module eval doesn't fail user-validation.
          users.users.openclaw = {
            isSystemUser = true;
            group = "openclaw";
          };
          users.groups.openclaw = { };
        }
      ];
    };

    openclaw-zdr-proxy-disabled = shouldEval "openclaw-zdr-proxy: disabled" {
      modules = [
        ../modules/services/openclaw-zdr-proxy.nix
        { services.openclaw-zdr-proxy.enable = false; }
      ];
    };

    # openclaw-zdr-proxy-sancta-claw-wiring, openclaw-free-zdr-ladder-rendered,
    # sancta-claw-openclaw-health-probe-zdr-alert: retired 2026-08-20 with
    # sancta-claw (see docs/retired.md) — these read
    # config.system.build.{openclawBrowserConfigBody,openclawHealthProbeBody}
    # and config.services.openclaw-zdr-proxy off self.nixosConfigurations.
    # sancta-claw specifically, which no longer exists. The standalone module
    # tests above (openclaw-zdr-proxy-minimal/-disabled) still guard
    # modules/services/openclaw-zdr-proxy.nix directly, independent of any
    # host, and are unaffected.

    # Verify the tailscale-dns-watchdog ships the same windowed crash-loop
    # breaker + operator alert (#450) on every host that imports the shared
    # tailscale module. Reads the rendered unit script — pure eval, no IFD.
    tailscale-dns-watchdog-breaker =
      let
        # sancta-claw, hermes-claw, zero-kuzea retired 2026-08-20 (destroyed
        # machines — see docs/retired.md); dropped from this list along with
        # them.
        hosts = [
          "rpi5"
          "rpi5-full"
          "sancta-choir"
        ];
        required = [
          "CRASH_LOOP_MAX"
          ''find "$RESTART_LOG_DIR" -maxdepth 1 -type f -mmin "-$CRASH_LOOP_WINDOW_MIN"''
          "NOT restarting"
          "Manual intervention needed"
          "exit 1"
        ];
        missingFor =
          host:
          let
            body = self.nixosConfigurations.${host}.config.systemd.services.tailscale-dns-watchdog.script;
          in
          builtins.filter (s: !(nixpkgs.lib.hasInfix s body)) required;
        failures = builtins.filter (h: missingFor h != [ ]) hosts;
        # rpi5-full must additionally wire the Telegram alert credentials.
        rpi5AlertWired =
          self.nixosConfigurations.rpi5-full.config.services.tailscale-dns-watchdog.telegramEnvFile != null;
      in
      if failures == [ ] && rpi5AlertWired then
        true
      else
        builtins.throw "FAIL: tailscale-dns-watchdog breaker — hosts missing sentinels: ${builtins.toJSON failures}; rpi5-full alert wired: ${builtins.toJSON rpi5AlertWired}";

    # hermes-claw-upstream-module, sancta-claw-smoke-test-zdr-checks: retired
    # 2026-08-20 with hermes-claw and sancta-claw respectively (see
    # docs/retired.md) — both read config off nixosConfigurations attributes
    # (hermes-claw, sancta-claw) that no longer exist.

    # ── sancta-statusline-refresh ─────────────────────────────────
    # The status bar renders a cached file and queries nothing itself, because
    # it runs on every prompt. This unit is the half that fills that file. On
    # 2026-08-01 only the renderer existed, so the bar showed a fifteen-hour-old
    # snapshot that looked perfectly current — six asks when there were fourteen.
    # Nothing was broken in a way any check could see; the renderer worked
    # correctly on stale input. These assertions pin the wiring that makes the
    # file get written at all.
    sancta-statusline-refresh-choir-wiring =
      let
        svc = self.nixosConfigurations.sancta-choir.config.systemd.services.sancta-statusline-refresh;
        timer = self.nixosConfigurations.sancta-choir.config.systemd.timers.sancta-statusline-refresh;
        soulRoot = toString self.nixosConfigurations.sancta-choir.config.services.sancta-soul-volume.mountPoint;
        # 2026-08-20: state.json moved into its own directory (index/statusline/)
        # so ReadWritePaths could target the DIRECTORY — atomic rename needs
        # directory-write, which a single-file entry cannot grant. See the
        # module's own comment on stateDir/ReadWritePaths for the reproduced
        # failure and why a directory holding exactly one file is still
        # least-privilege.
        stateDir = "${soulRoot}/index/statusline";
        stateFile = "${stateDir}/state.json";
        refreshScript = "${soulRoot}/index/bin/statusline-refresh";

        checks = {
          # Mount-gated: without the soul volume the state file's directory does
          # not exist, and a run would fail every fifteen minutes forever.
          mountGated = svc.unitConfig.ConditionPathIsMountPoint or null == soulRoot;
          requiresMount = builtins.elem "sancta-soul-mount.service" (svc.requires or [ ]);

          # Exactly ONE writable path, and it must be the state DIRECTORY, not
          # the state file (changed 2026-08-20): the refresher's atomic write is
          # mktemp-a-sibling-then-mv, and rename(2) needs write on the
          # containing directory, not just the file being replaced — a
          # single-file ReadWritePaths entry cannot satisfy that, which is
          # exactly the bug this move fixes (reproduced live: state dir chmod
          # 555, refresher's mktemp fails, unit exits 1). Still least-privilege:
          # `stateDir` holds exactly one file (state.json) and nothing else, so
          # the writable blast radius is unchanged in practice — only the grant
          # now matches what rename(2) actually requires. `-` prefixed (review
          # finding, 2026-08-19, still applies to the directory form): a bare
          # path that does not exist yet fails the ProtectSystem=strict
          # bind-mount before the unit ever starts; `-` is systemd's documented
          # "ignore if absent" marker, not a widening — the directory is still
          # the ONLY writable path, and it holds nothing but the one file.
          onlyStateWritable = (svc.serviceConfig.ReadWritePaths or [ ]) == [ "-${stateDir}/" ];

          # Network is REQUIRED here, unlike the doctrine guard: the ask list
          # comes from GitHub. If this were ever narrowed to AF_UNIX the unit
          # would still start, still exit 0, and silently write an empty ask
          # list — which the bar renders as a clear queue.
          hasNetwork =
            builtins.elem "AF_INET" (svc.serviceConfig.RestrictAddressFamilies or [ ])
            && builtins.elem "AF_UNIX" (svc.serviceConfig.RestrictAddressFamilies or [ ]);

          # The cadence has to stay far below the twelve hours after which the
          # bar starts marking itself stale, or the number means "recently"
          # rather than "now".
          timerEvery15 = (timer.timerConfig.OnCalendar or "") == "*:0/15";

          # After a reboot the bar would otherwise render whatever the file held
          # when the machine went down, with no marker for twelve hours.
          catchesUp = (timer.timerConfig.Persistent or false) == true;

          # A run that outlives its own cadence stacks refreshes instead of
          # replacing them.
          boundedRun = (svc.serviceConfig.TimeoutStartSec or "") == "3m";

          # Single-source-of-logic (amended 2026-08-19): ExecStart must invoke
          # the INDEX repo's script directly — this module carries no refresh
          # logic of its own, only the clock and the contract.
          execIsIndexScript = (svc.serviceConfig.ExecStart or "") == refreshScript;

          # ExecStart is deliberately NOT a store path (see the module's "WORKS-
          # BY-LUCK TRAP" comment), so tests/unit-script-refs.nix cannot verify
          # it resolves. ExecStartPre must be the replacement guard: a real
          # existence+executable check on the exact script path.
          hasExistenceGuard = (svc.serviceConfig.ExecStartPre or "") == "${pkgs.coreutils}/bin/test -x ${refreshScript}";

          # The env contract: the three variables the INDEX script requires,
          # exactly as agreed — a drift here silently breaks the script even
          # though the unit itself stays green.
          hasEnvContract =
            let
              env = svc.serviceConfig.Environment or [ ];
            in
            builtins.elem "SANCTA_STATUSLINE_STATE=${stateFile}" env
            && builtins.elem "SANCTA_STATUSLINE_REPO=alexandru-savinov/nixos-config" env
            && builtins.elem "SANCTA_STATUSLINE_UNITS=sancta-gallery.service sancta-doctrine-guard.service sancta-soul-mirror.timer" env;
        };

        failed = builtins.attrNames (nixpkgs.lib.filterAttrs (_: v: !v) checks);
      in
      if failed == [ ] then
        true
      else
        builtins.throw "FAIL: sancta-choir statusline-refresh wiring — failed checks: ${builtins.toJSON failed}";

    # An empty `units` list makes a host with dead services render identically
    # to a healthy one: the bar's "down" field can never populate. That is the
    # exact silent-pass this module family exists to prevent, so it must fail at
    # build time rather than ship a bar that cannot report.
    sancta-statusline-refresh-empty-units-rejected =
      shouldFail "statusline-refresh: empty units list rejected"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-statusline-refresh.nix
            {
              services.sancta-soul-volume = {
                enable = true;
                keyFile = "/run/agenix/soul-volume-key";
              };
              services.sancta-statusline-refresh = {
                enable = true;
                units = [ ];
              };
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

  };

  # ── Build the check derivation ──────────────────────────────────
  # Each test returns `true` on success or calls `builtins.throw` on
  # failure. Sequencing `builtins.deepSeq allResults` forces every test
  # to evaluate; a throw aborts immediately and `nix flake check` reports it.
  testNames = builtins.attrNames tests;
  testCount = builtins.length testNames;
  allResults = builtins.attrValues tests;

in
pkgs.runCommand "module-eval-tests"
{
  passthru = { inherit tests; };
}
  # deepSeq ensures all test thunks are forced before the builder runs.
  (
    builtins.deepSeq allResults ''
      echo "All ${toString testCount} module evaluation tests passed:"
      ${builtins.concatStringsSep "\n" (map (name: "echo '  ✓ ${name}'") testNames)}
      echo "${toString testNames}" > $out
    ''
  )
