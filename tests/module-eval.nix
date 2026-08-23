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
        # 2026-08-21: the script's stale-probe opens index/orchestrator/queue.db
        # (WAL-mode sqlite) READ-ONLY via node:sqlite. A WAL reader still needs
        # write access to that database's `-shm` sidecar — SQLite's WAL reader
        # contract, not a script choice — so under ProtectSystem=strict the
        # open failed without this directory writable too, and the stale-probe
        # silently degraded to -1 ("⚠ stale ?") while the unit still exited 0.
        # See the module's own comment on orchestratorDir/ReadWritePaths for
        # the reproduced failure.
        orchestratorDir = "${soulRoot}/index/orchestrator";
        refreshScript = "${soulRoot}/index/bin/statusline-refresh";

        checks = {
          # Mount-gated: without the soul volume the state file's directory does
          # not exist, and a run would fail every fifteen minutes forever.
          mountGated = svc.unitConfig.ConditionPathIsMountPoint or null == soulRoot;
          requiresMount = builtins.elem "sancta-soul-mount.service" (svc.requires or [ ]);

          # Exactly TWO writable paths (changed 2026-08-21 — see orchestratorDir
          # above), each the narrowest directory one part of the script
          # structurally needs to touch:
          #
          # - the state DIRECTORY, not the state file (changed 2026-08-20): the
          #   refresher's atomic write is mktemp-a-sibling-then-mv, and
          #   rename(2) needs write on the containing directory, not just the
          #   file being replaced — a single-file ReadWritePaths entry cannot
          #   satisfy that (reproduced live: state dir chmod 555, refresher's
          #   mktemp fails, unit exits 1). Still least-privilege: `stateDir`
          #   holds exactly one file (state.json) and nothing else.
          # - the orchestrator DIRECTORY (added 2026-08-21): the stale-probe's
          #   WAL-mode read of queue.db needs write access to that db's `-shm`
          #   sidecar even though the open itself is read-only — without this
          #   entry the probe silently degrades to -1 instead of failing loudly.
          #
          # Both `-` prefixed (review finding, 2026-08-19, still applies to the
          # directory form): a bare path that does not exist yet fails the
          # ProtectSystem=strict bind-mount before the unit ever starts; `-` is
          # systemd's documented "ignore if absent" marker, not a widening —
          # these two directories are still the ONLY writable paths, and each
          # holds nothing but what the one part of the script it serves needs.
          onlyStateAndOrchestratorWritable =
            (svc.serviceConfig.ReadWritePaths or [ ]) == [
              "-${stateDir}/"
              "-${orchestratorDir}/"
            ];

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
            # sancta-wq-tick.service joined this list on 2026-08-22: the queue's
            # heartbeat reports trouble through the dead-letter, but only for
            # failures that happen INSIDE a tick — a unit that dies before any
            # queue bookkeeping (missing script, node import failure, a
            # ReadWritePaths bind-mount that won't start) writes nothing at all
            # and would stop as silently as the stall this repo just fixed.
            && builtins.elem "SANCTA_STATUSLINE_UNITS=sancta-gallery.service sancta-doctrine-guard.service sancta-soul-mirror.timer sancta-wq-tick.service" env;
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

    # ── sancta-wq-tick ────────────────────────────────────────────
    # The work queue's handlers are what keep the rest of the substrate honest
    # — soul-mirror health, MEMORY.md parity, witness requests rotting past
    # seven days, ExecStart contract drift. Until 2026-08-22 the only thing that
    # ran them was a live session happening to call bin/wq-tick, which is a
    # coincidence rather than a clock. It failed the way coincidences fail: on
    # 2026-08-21 and again on 2026-08-22 the status bar's `stale` counter read 7
    # — seven overdue tasks, twice — with nothing anywhere reporting that the
    # beat itself had stopped. These assertions pin the wiring that makes the
    # beat happen at all, and the two properties that decide whether it recovers
    # on its own: Persistent (a missed beat catches up) and a writable set that
    # actually covers what the handlers write (a false-narrow list fails at 3am,
    # not here).
    sancta-wq-tick-choir-wiring =
      let
        svc = self.nixosConfigurations.sancta-choir.config.systemd.services.sancta-wq-tick;
        timer = self.nixosConfigurations.sancta-choir.config.systemd.timers.sancta-wq-tick;
        soulRoot = toString self.nixosConfigurations.sancta-choir.config.services.sancta-soul-volume.mountPoint;
        indexRoot = "${soulRoot}/index";
        tickScript = "${indexRoot}/bin/wq-tick";
        orchestratorDir = "${indexRoot}/orchestrator";
        statuslineDir = "${indexRoot}/statusline";
        configRepo = "/var/lib/sancta/repos/nixos-config";

        checks = {
          # Without the soul volume there is no queue database, no tick script
          # and no handlers — a beat every half hour that can only fail.
          mountGated = svc.unitConfig.ConditionPathIsMountPoint or null == soulRoot;
          requiresMount = builtins.elem "sancta-soul-mount.service" (svc.requires or [ ]);

          # THE WAL × SANDBOX RELATION, which is where this class of bug lives.
          # Both directories, not the files inside them: bin/wq-tick writes
          # queue.db through SQLite in WAL mode (which creates and renames -wal
          # and -shm siblings, plus the flock file), and the statusline-refresh
          # handler writes its state through mktemp-a-sibling-then-rename.
          # rename(2) and sibling-creation both need write on the CONTAINING
          # DIRECTORY — a file-granular entry cannot satisfy either, which this
          # repo already reproduced live on 2026-08-20 for the statusline unit.
          # Asserted as exact list equality so that WIDENING it (to all of
          # index/, say) is also a failing change and has to be argued for,
          # not just typed.
          writablePathsExact =
            (svc.serviceConfig.ReadWritePaths or [ ]) == [
              "-${orchestratorDir}/"
              "-${statuslineDir}/"
              "-${configRepo}/.git/"
            ];

          # Network is REQUIRED, un-narrowed: the freshness handler curls the
          # gallery over the tailnet and the membrane on loopback, the
          # statusline handler talks to GitHub through gh, and the contract-drift
          # handler fetches over https. Narrowed to AF_UNIX this unit would
          # still start and still exit 0 — every network probe would just report
          # a dead surface forever.
          hasNetwork =
            builtins.elem "AF_INET" (svc.serviceConfig.RestrictAddressFamilies or [ ])
            && builtins.elem "AF_INET6" (svc.serviceConfig.RestrictAddressFamilies or [ ])
            && builtins.elem "AF_UNIX" (svc.serviceConfig.RestrictAddressFamilies or [ ]);

          timerEvery30 = (timer.timerConfig.OnCalendar or "") == "*:0/30";

          # The incident this whole unit answers. Without Persistent, a host
          # that was down — or a beat that was simply missed — resumes at the
          # next half hour with the overdue tasks still overdue and nothing
          # saying so, which is precisely the silent stall of 2026-08-21/22.
          catchesUp = (timer.timerConfig.Persistent or false) == true;

          # One tick claims at most three tasks at 60s each; five minutes leaves
          # headroom and stays far under the thirty-minute cadence, so a slow
          # beat cannot stack on the next one.
          boundedRun = (svc.serviceConfig.TimeoutStartSec or "") == "5m";

          # CONCURRENCY. Two properties in one string, both load-bearing:
          # `--nonblock` (never queue behind a running beat) and
          # `--conflict-exit-code 0` (a skipped beat is the system working, not
          # a failure — a unit that goes red every time it is busy trains its
          # reader to ignore it).
          execIsFlockWrappedScript =
            (svc.serviceConfig.ExecStart or "")
            == "${pkgs.util-linux}/bin/flock --nonblock --conflict-exit-code 0 ${orchestratorDir}/wq-tick.lock ${tickScript}";

          # ExecStart is deliberately NOT a store path (the script lives on the
          # soul volume), so tests/unit-script-refs.nix is blind to it. This is
          # the replacement guard, same as sancta-statusline-refresh's.
          hasExistenceGuard = (svc.serviceConfig.ExecStartPre or "") == "${pkgs.coreutils}/bin/test -x ${tickScript}";

          # bin/wq-tick exits 3 on orchestrator/STOP — a deliberate halt, not an
          # error. Without this the STOP file would paint the unit failed every
          # half hour, and the bar would report a broken clock while the clock
          # was obeying an instruction.
          stopIsNotFailure = (svc.serviceConfig.SuccessExitStatus or "") == "3";

          # queue.mjs derives the database path from $HOME. systemd gives a
          # service none by default, and queue.mjs's own fallback happens to be
          # right on this host — right by luck is not a thing to ship.
          hasHomeContract = builtins.elem "HOME=${builtins.dirOf soulRoot}" (svc.serviceConfig.Environment or [ ]);

          # THE HEARTBEAT IS ITSELF WATCHED. A tick that fails INSIDE a handler
          # lands in the queue's dead-letter, which the bar already renders. A
          # unit that dies BEFORE any queue bookkeeping — script missing, node
          # import failure, a bind-mount that stops the unit from starting —
          # writes nothing anywhere, and without this the heartbeat would go
          # silent exactly the way the stall it fixes did. Asserted here, in the
          # wq-tick block rather than only in the statusline one, so that
          # dropping the unit from that list fails as a wq-tick regression.
          selfIsWatched =
            builtins.elem "sancta-wq-tick.service"
              self.nixosConfigurations.sancta-choir.config.services.sancta-statusline-refresh.units;

          # THE PATH CONTRACT, at the input end. bin/wq-tick is a dispatcher:
          # the handler scripts it invokes by absolute path run as children of
          # THIS unit and resolve their own commands through THIS PATH, so a
          # missing package here breaks the queue at 3am and nothing at build
          # time. What each one supplies is enumerated in the module and checked
          # against the rendered PATH= by tests/execstart-path-contract.nix;
          # this assertion pins that they are wired in the first place.
          pathHasContract =
            let
              p = svc.path or [ ];
              has = pkg: builtins.elem pkg p;
            in
            builtins.all has [
              pkgs.nodejs
              pkgs.bash
              pkgs.curl
              pkgs.systemd
              pkgs.git
              pkgs.gh
              pkgs.jq
              pkgs.gnugrep
              pkgs.procps
              pkgs.coreutils
            ];
        };

        failed = builtins.attrNames (nixpkgs.lib.filterAttrs (_: v: !v) checks);
      in
      if failed == [ ] then
        true
      else
        builtins.throw "FAIL: sancta-choir wq-tick wiring — failed checks: ${builtins.toJSON failed}";

    # Negative arm 1: the queue database, the tick script and every handler live
    # on the soul volume. Enabled without it, the unit would be a timer that can
    # only fail — and would fail from inside a sandbox whose ReadWritePaths point
    # at directories that do not exist, i.e. opaquely, at the systemd layer,
    # every half hour. Refuse at build time instead.
    sancta-wq-tick-without-soul-volume-rejected =
      shouldFail "wq-tick: requires the soul volume"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-wq-tick.nix
            {
              services.sancta-soul-volume.enable = false;
              services.sancta-wq-tick.enable = true;
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

    # Negative arm 2 — the one that proves the nodejs assertion can actually
    # LOSE. orchestrator/queue.mjs imports `node:sqlite`, which does not exist
    # before Node 22: on an older nodejs this unit evaluates, builds, activates,
    # and then dies at the first import every half hour on a host nobody is
    # watching. The version is faked by overlay rather than by pinning a real
    # old nodejs so the arm costs one eval and no download — `//` keeps the
    # derivation's outPath, so `path = [ nodejs ]` still renders and the ONLY
    # thing that changes is the fact the assertion reads.
    sancta-wq-tick-old-nodejs-rejected =
      shouldFail "wq-tick: rejects nodejs older than 22 (node:sqlite)"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-wq-tick.nix
            {
              nixpkgs.overlays = [ (_final: prev: { nodejs = prev.nodejs // { version = "20.19.0"; }; }) ];
              services.sancta-soul-volume = {
                enable = true;
                keyFile = "/run/agenix/soul-volume-key";
              };
              services.sancta-wq-tick.enable = true;
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

    # Negative arm 3 — the range the FIRST version of this assertion let
    # through (review finding, 2026-08-22). node:sqlite exists on 22.12, so an
    # assertion written as `versionAtLeast "22"` passes there; queue.mjs passes
    # no --experimental-sqlite, and on 22.12 the module is still behind that
    # flag, so the unit would activate and then die at the first import every
    # half hour. A negative arm that only tries Node 20 cannot see this — it is
    # the permitted-but-broken middle, which is where a version floor is
    # actually wrong or right.
    sancta-wq-tick-flagged-nodejs-rejected =
      shouldFail "wq-tick: rejects nodejs 22.12 (node:sqlite still behind a flag)"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-wq-tick.nix
            {
              nixpkgs.overlays = [ (_final: prev: { nodejs = prev.nodejs // { version = "22.12.0"; }; }) ];
              services.sancta-soul-volume = {
                enable = true;
                keyFile = "/run/agenix/soul-volume-key";
              };
              services.sancta-wq-tick.enable = true;
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

    # ── sancta-transcript-archive ─────────────────────────────────
    # The verbatim transcript (530 MB, ~0.5 GB/month) lives on ONE volume and
    # the weekly mirror tar excludes it by design, so until this unit it had no
    # second copy anywhere. These assertions pin the wiring that decides whether
    # the archive is (a) produced at all, (b) actually carried to rpi5, and
    # (c) unable to leak in clear or to damage the source — the three ways this
    # can be quietly wrong while every unit still reports green.
    sancta-transcript-archive-choir-wiring =
      let
        choir = self.nixosConfigurations.sancta-choir.config;
        svc = choir.systemd.services.sancta-transcript-archive;
        timer = choir.systemd.timers.sancta-transcript-archive;
        soulRoot = toString choir.services.sancta-soul-volume.mountPoint;
        archiveScript = "${soulRoot}/index/bin/transcript-archive";
        sourceDir = "${soulRoot}/projects";
        localDir = choir.services.sancta-soul-mirror.localDir;
        publishedDir = "${localDir}/soul-archive";
        stateDir = "/var/lib/sancta/transcript-archive";
        env = svc.serviceConfig.Environment or [ ];

        checks = {
          # Without the mount, the underlay directory is empty: a scan finds no
          # transcripts, and but for the producer's own empty-source guard the
          # run would exit 0 "healthy" while the guard read the same emptiness
          # and confirmed it. `requires` alone does not close this — a
          # ConditionPathExists-skipped mount still satisfies Requires=.
          mountGated = svc.unitConfig.ConditionPathIsMountPoint or null == soulRoot;
          requiresMount = builtins.elem "sancta-soul-mount.service" (svc.requires or [ ]);

          # THE TRANSPORT FACT. The objects reach rpi5 only because they sit
          # under the mirror's localDir: the forced command is
          # `rrsync -ro <localDir>` and the puller asks for remoteDir = "/".
          # Move them one directory up or sideways and the archive still looks
          # perfect on this host while no second copy exists anywhere.
          publishedUnderMirror =
            (choir.services.sancta-transcript-archive.publishedDir) == publishedDir
            && nixpkgs.lib.hasPrefix "${localDir}/" "${publishedDir}/";

          # THE ZERO-KNOWLEDGE FACT, the same relation read the other way. The
          # canonical manifest, the heartbeat and INDEX.md are plaintext
          # metadata (project names, session ids, sizes, a timeline); rpi5
          # pulls EVERYTHING under localDir, so they must live outside it.
          stateOutsidePublished =
            (choir.services.sancta-transcript-archive.stateDir) == stateDir
            && !(nixpkgs.lib.hasPrefix "${localDir}/" "${stateDir}/");

          # Exactly the two archive directories, as directories (rename(2)
          # needs write on the CONTAINING directory — reproduced live in this
          # repo on 2026-08-20) and `-` prefixed (a bare path that does not
          # exist yet fails the ProtectSystem=strict bind-mount before the unit
          # can produce its own honest error). Exact list equality so that
          # WIDENING it is a failing change that has to be argued for.
          writablePathsExact =
            (svc.serviceConfig.ReadWritePaths or [ ]) == [
              "-${publishedDir}/"
              "-${stateDir}/"
            ];

          # "NEVER delete, move or rewrite a source transcript" as a property of
          # the SANDBOX, not a promise in a script: ProtectSystem=strict makes
          # everything read-only except ReadWritePaths, and the source tree is
          # under neither entry. This is the falsifiable form of the module's
          # deliberate choice not to write a redundant ReadOnlyPaths line.
          sourceNotWritable =
            (svc.serviceConfig.ProtectSystem or "") == "strict"
            && !(builtins.any
              (p: nixpkgs.lib.hasPrefix (nixpkgs.lib.removePrefix "-" p) "${sourceDir}/")
              (svc.serviceConfig.ReadWritePaths or [ ]));

          # NO NETWORK. This producer reads local files, encrypts to public keys
          # and writes local files; rpi5 dials IN for the transport. Anything
          # that tried to send a transcript anywhere fails at the socket.
          noNetwork = (svc.serviceConfig.RestrictAddressFamilies or [ ]) == [ "AF_UNIX" ];

          # DAILY. The guard alarms when the heartbeat is older than two days,
          # which only leaves room for one missed beat if the cadence is daily —
          # the weekly shape borrowed from the mirror would tolerate a week of
          # silence before anything noticed.
          timerDaily = (timer.timerConfig.OnCalendar or "") == "*-*-* 04:20:00";

          # A missed beat otherwise waits a full day, and the two-day heartbeat
          # threshold turns one missed beat into an alarm.
          catchesUp = (timer.timerConfig.Persistent or false) == true;

          # CONCURRENCY, both properties load-bearing: `--nonblock` (never queue
          # behind a running run) and `--conflict-exit-code 0` (a beat skipped
          # while a hand-run is in flight is the system working, not a failure).
          execIsFlockWrappedScript =
            (svc.serviceConfig.ExecStart or "")
            == "${pkgs.util-linux}/bin/flock --nonblock --conflict-exit-code 0 ${stateDir}/transcript-archive.lock ${archiveScript}";

          # ExecStart is deliberately NOT a store path (the script lives on the
          # soul volume in the INDEX repo), so tests/unit-script-refs.nix is
          # blind to it. Same replacement guard as the other two soul units.
          hasExistenceGuard = (svc.serviceConfig.ExecStartPre or "") == "${pkgs.coreutils}/bin/test -x ${archiveScript}";

          # THE ENV CONTRACT the INDEX script reads. A drift here breaks the
          # script while the unit itself stays green — except for the source
          # path, where a wrong value means scanning an empty directory, which
          # the producer treats as an error rather than a clean run.
          hasEnvContract =
            builtins.elem "SANCTA_ARCHIVE_SOURCE=${sourceDir}" env
            && builtins.elem "SANCTA_ARCHIVE_PUBLISHED=${publishedDir}" env
            && builtins.elem "SANCTA_ARCHIVE_STATE=${stateDir}" env
            # CLOSED_AFTER is double-duty: the producer's live-file rule AND
            # the archive-check guard's missing-session threshold (the guard
            # reads the same variable and adds 24h of margin). If you retune
            # closedAfterSec, update this pin too — the guard follows the
            # value automatically; this string is the only thing that drifts.
            && builtins.elem "SANCTA_ARCHIVE_CLOSED_AFTER=172800" env;

          # RECIPIENTS AS A FILE, and it is the mirror's list verbatim.
          # A recipient can contain a SPACE — the mirror's second recipient is
          # an `ssh-ed25519 AAAA…` pubkey — so the space-separated env form
          # cannot represent the real list at all (reproduced 2026-08-23:
          # `age: error: malformed SSH recipient: "ssh-ed25519"`). This asserts
          # both halves: the file form is what the unit passes, and its
          # CONTENTS are exactly the mirror's recipients, one per line.
          recipientsFileIsMirrorList =
            let
              prefix = "SANCTA_ARCHIVE_RECIPIENTS_FILE=";
              entry = nixpkgs.lib.findFirst (e: nixpkgs.lib.hasPrefix prefix e) null env;
              file = if entry == null then null else nixpkgs.lib.removePrefix prefix entry;
              mirrorRecipients = choir.services.sancta-soul-mirror.recipients;
            in
            file != null
            && builtins.readFile file == nixpkgs.lib.concatStringsSep "\n" mirrorRecipients + "\n"
            && builtins.length mirrorRecipients >= 2;

          # A daily unit that touches no network can afford a loud failure path,
          # unlike the 15-minute statusline refresher. Its failure means the
          # second copy silently stopped being made.
          alertsOnFailure = builtins.elem "sancta-soul-mirror-alert@%N.service" (svc.onFailure or [ ]);

          # THE PATH CONTRACT at the input end — `bash` first and not optional,
          # since the script's `#!/usr/bin/env bash` shebang resolves the
          # INTERPRETER through this PATH. What each package supplies is checked
          # against the rendered PATH= by tests/execstart-path-contract.nix;
          # this pins that they are wired at all.
          pathHasContract =
            let
              p = svc.path or [ ];
            in
            builtins.all (pkg: builtins.elem pkg p) [
              pkgs.bash
              pkgs.age
              pkgs.jq
              pkgs.coreutils
              pkgs.findutils
            ];

          # Both directories exist, 0700, owned by the archiving user, before
          # the first beat: under ProtectSystem=strict the mirror's localDir is
          # read-only to this unit, so a first run on a fresh host could not
          # create the published subdirectory itself.
          tmpfilesCreateBothDirs =
            let
              rules = choir.systemd.tmpfiles.rules or [ ];
            in
            builtins.elem "d ${stateDir} 0700 sancta - -" rules
            && builtins.elem "d ${publishedDir} 0700 sancta - -" rules;
        };

        failed = builtins.attrNames (nixpkgs.lib.filterAttrs (_: v: !v) checks);
      in
      if failed == [ ] then
        true
      else
        builtins.throw "FAIL: sancta-choir transcript-archive wiring — failed checks: ${builtins.toJSON failed}";

    # Negative arm 1 — the length check the mirror's own assertion cannot make.
    # services.sancta-soul-mirror asserts only that every entry LOOKS like a key
    # (`builtins.all` over a prefix test), which passes on a one-entry list and
    # on an empty one. Reusing that list without a length check would ship an
    # archive one lost key away from unreadable, and nothing would say so until
    # a restore was attempted.
    sancta-transcript-archive-single-recipient-rejected =
      shouldFail "transcript-archive: rejects a single-recipient list"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-soul-mirror.nix
            ../modules/services/sancta-transcript-archive.nix
            {
              services.sancta-soul-volume = {
                enable = true;
                keyFile = "/run/agenix/soul-volume-key";
              };
              services.sancta-soul-mirror = {
                enable = true;
                # One entry, and a REAL key shape — so the mirror's own prefix
                # assertion passes and only the length check can catch it.
                recipients = [ "age1d3qlm08ncrd5ksk4mzypzlx7n8lge2yqd0ejsfvcanz03a9g3csqq2pwtq" ];
              };
              services.sancta-transcript-archive.enable = true;
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

    # Negative arm 2 — the zero-knowledge invariant, made unrepresentable rather
    # than merely forbidden. rpi5's puller asks for remoteDir = "/", so anything
    # under the published directory leaves this host on the next pull. A
    # stateDir moved inside it would publish the canonical plaintext manifest —
    # project names, session ids, sizes, a timeline — with every unit still
    # green and no check anywhere failing. It must fail at build time.
    sancta-transcript-archive-plaintext-state-in-published-dir-rejected =
      shouldFail "transcript-archive: rejects a stateDir under the published mirror dir"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-soul-mirror.nix
            ../modules/services/sancta-transcript-archive.nix
            {
              services.sancta-soul-volume = {
                enable = true;
                keyFile = "/run/agenix/soul-volume-key";
              };
              services.sancta-soul-mirror.enable = true;
              services.sancta-transcript-archive = {
                enable = true;
                stateDir = "/var/lib/sancta/soul-mirror/transcript-archive";
              };
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

    # Negative arm 3 — the same relation read the other way. Objects written
    # OUTSIDE the mirror's localDir are unreachable by the forced rrsync
    # command, so rpi5 never pulls them: the archive would look complete on the
    # host it is meant to be a backup OF, and exist nowhere else.
    sancta-transcript-archive-published-outside-mirror-rejected =
      shouldFail "transcript-archive: rejects a publishedDir outside the mirror's localDir"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-soul-mirror.nix
            ../modules/services/sancta-transcript-archive.nix
            {
              services.sancta-soul-volume = {
                enable = true;
                keyFile = "/run/agenix/soul-volume-key";
              };
              services.sancta-soul-mirror.enable = true;
              services.sancta-transcript-archive = {
                enable = true;
                publishedDir = "/var/lib/sancta/soul-archive";
              };
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

    # Negative arm 4 — without the mirror there is no published directory, no
    # 0700 tmpfiles rule for it and no rrsync endpoint. The unit would write
    # ciphertext into a directory nothing serves and nothing pulls: a backup
    # that exists only on the host it is backing up.
    sancta-transcript-archive-without-mirror-rejected =
      shouldFail "transcript-archive: requires the soul-mirror (endpoint + published dir)"
        {
          modules = [
            ../hosts/sancta-choir/soul-volume.nix
            ../modules/services/sancta-soul-mirror.nix
            ../modules/services/sancta-transcript-archive.nix
            {
              services.sancta-soul-volume = {
                enable = true;
                keyFile = "/run/agenix/soul-volume-key";
              };
              services.sancta-soul-mirror.enable = false;
              services.sancta-transcript-archive.enable = true;
              users.users.sancta = {
                isSystemUser = true;
                group = "sancta";
              };
              users.groups.sancta = { };
            }
          ];
        };

    # ── claude-code-managed-settings ────────────────────────────────
    # /etc/claude-code/managed-settings.json exists specifically because a
    # running Claude Code session rewrites ~/.claude/settings.json from its
    # own in-memory copy and silently drops any key it never saw — proven
    # live on 2026-08-20 (statusLine + hooks.UserPromptSubmit both gone twice
    # in one day). These assertions pin that exactly the three agreed keys
    # render, and nothing else — since managed settings OVERRIDE the owner's
    # own file, a fourth key here is a silent capability-removal from him, not
    # a cosmetic drift.
    #
    # 2026-08-20, PR #569 finding P1: statusLine and the memory-index hook are
    # rendered as GUARDED commands, not bare paths — see the module header's
    # CROSS-USER SAFETY section. This file is machine-wide (root, herdr,
    # sancta all read it) and both scripts live under the 0700-sancta-only
    # soul volume, so each command self-checks `id -un` = sancta before
    # exec'ing; a non-sancta account gets an instant no-op instead of a
    # permission-denied path. spinnerTipsEnabled moved OUT of this file
    # entirely (a preference, not infrastructure — a single machine-wide JSON
    # literal cannot be scoped to one account the way a command string can);
    # its durable home is now
    # home-manager.users.sancta.programs.claude-code.extraSettings.
    claude-code-managed-settings-choir-wiring =
      let
        etcEntry =
          self.nixosConfigurations.sancta-choir.config.environment.etc."claude-code/managed-settings.json";
        rendered = builtins.fromJSON etcEntry.text;
        guarded = path: ''[ "$(id -un)" = sancta ] && exec ${path}; exit 0'';

        checks = {
          # World-readable, not writable by anything but root/Nix — see the
          # module header's FILE MODE note (upstream leaves this
          # undocumented; 0644 is the chosen conservative default).
          modeIsReadOnly = etcEntry.mode == "0644";

          hasStatusLine =
            rendered.statusLine or null
            == {
              type = "command";
              command = guarded "/var/lib/sancta/.claude/statusline.sh";
            };

          hasClockHook =
            (rendered.hooks.UserPromptSubmit or [ ])
            == [
              {
                hooks = [
                  {
                    type = "command";
                    command = "date '+Now: %A %Y-%m-%d %H:%M %Z'";
                  }
                ];
              }
            ];

          hasMemoryIndexHook =
            (rendered.hooks.PostToolUse or [ ])
            == [
              {
                matcher = "Write|Edit";
                hooks = [
                  {
                    type = "command";
                    command = guarded "/var/lib/sancta/.claude/index/bin/memory-index-hook";
                  }
                ];
              }
            ];

          # Both guarded commands must actually mention the `id -un = sancta`
          # check — a belt-and-braces assertion that the wiring didn't
          # silently degrade back into a bare path (the exact P1 regression
          # this all exists to prevent) if the module is ever refactored.
          statusLineIsGuarded =
            nixpkgs.lib.hasInfix ''"$(id -un)" = sancta'' rendered.statusLine.command;
          memoryHookIsGuarded =
            nixpkgs.lib.hasInfix ''"$(id -un)" = sancta''
              (builtins.head (builtins.head (rendered.hooks.PostToolUse)).hooks).command;

          spinnerTipsNotInManagedFile = !(rendered ? spinnerTipsEnabled);

          # The hard limit this module promises in its own header: managed
          # settings override the owner's file, so a key beyond the three
          # agreed ones is a silent capability-removal, not a convenience.
          # This fails loudly the moment a fourth key is added without also
          # updating this assertion — the reviewing human, not a rebuild.
          exactlyThreeKeys = (builtins.attrNames rendered) == [
            "hooks"
            "statusLine"
          ];
        };

        failed = builtins.attrNames (nixpkgs.lib.filterAttrs (_: v: !v) checks);
      in
      if failed == [ ] then
        true
      else
        builtins.throw "FAIL: sancta-choir claude-code-managed-settings wiring — failed checks: ${builtins.toJSON failed}";

    # spinnerTipsEnabled's new, sancta-scoped home (2026-08-20, PR #569
    # finding P1) — moved out of the machine-wide managed file specifically
    # because it is a preference no single JSON literal there can scope to
    # one account; confirm it actually landed where the header now says it
    # does, not just that it left the managed file above.
    claude-code-managed-settings-spinner-tips-scoped-home =
      let
        extra =
          self.nixosConfigurations.sancta-choir.config.home-manager.users.sancta.programs.claude-code.extraSettings
            or { };
      in
      if (extra.spinnerTipsEnabled or null) == false then
        true
      else
        builtins.throw "FAIL: spinnerTipsEnabled did not land in home-manager.users.sancta.programs.claude-code.extraSettings (got: ${builtins.toJSON extra})";

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
