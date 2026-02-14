# OpenClaw MicroVM Implementation Plan

Based on: https://buduroiu.com/blog/openclaw-microvm/

## Goal

Replace the current `modules/services/openclaw.nix` (Claude Code CLI wrapper) with a microVM running the official OpenClaw with native Telegram integration.

## Architecture

```
sancta-choir (host)
├── Bridge: br-openclaw (192.168.83.1/24)
├── Unbound DNS resolver (logs all queries)
├── nftables (NAT + connection logging)
└── MicroVM: openclaw-vm (192.168.83.2)
    ├── Official OpenClaw (Node.js)
    ├── Telegram bot (native grammY)
    └── Secret mounts via virtiofs
```

## File Structure

```
modules/
├── microvm/
│   ├── base.nix              # Shared microVM config
│   └── openclaw-vm.nix       # OpenClaw-specific VM
└── services/
    └── openclaw.nix          # DEPRECATED (keep for reference)

hosts/sancta-choir/
├── configuration.nix         # Enable microVM
└── openclaw-vm.nix          # VM guest config
```

## Implementation Steps

### Step 1: Add microvm.nix Flake Input

`flake.nix`:
```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

### Step 2: Create Base MicroVM Module

`modules/microvm/base.nix`:
```nix
{ config, lib, pkgs, ... }:

with lib;

{
  options.customModules.microvm-base = {
    enable = mkEnableOption "Base microVM configuration";

    vmName = mkOption {
      type = types.str;
      description = "VM name";
    };

    ipAddress = mkOption {
      type = types.str;
      description = "Static IP on bridge network";
    };

    vcpu = mkOption {
      type = types.int;
      default = 2;
    };

    memory = mkOption {
      type = types.int;
      default = 2048;
      description = "Memory in MB";
    };
  };

  config = mkIf config.customModules.microvm-base.enable {
    microvm = {
      hypervisor = "cloud-hypervisor";

      vcpu = config.customModules.microvm-base.vcpu;
      mem = config.customModules.microvm-base.memory;

      interfaces = [{
        type = "tap";
        id = "vm-${config.customModules.microvm-base.vmName}";
        mac = "02:00:00:00:00:01";
      }];

      shares = [
        {
          proto = "virtiofs";
          tag = "ro-store";
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
        }
        {
          proto = "virtiofs";
          tag = "secrets";
          source = "/run/openclaw-secrets";
          mountPoint = "/run/secrets";
        }
      ];
    };

    # Networking inside VM
    networking = {
      hostName = config.customModules.microvm-base.vmName;
      useNetworkd = true;
      useDHCP = false;

      defaultGateway = {
        address = "192.168.83.1";
        interface = "eth0";
      };

      interfaces.eth0 = {
        ipv4.addresses = [{
          address = config.customModules.microvm-base.ipAddress;
          prefixLength = 24;
        }];
      };

      nameservers = [ "192.168.83.1" ];
    };

    # Allow systemd-resolved in VM
    services.resolved.enable = true;
  };
}
```

### Step 3: Create OpenClaw VM Module

`modules/microvm/openclaw-vm.nix`:
```nix
{ config, lib, pkgs, nix-openclaw, ... }:

with lib;

let
  cfg = config.services.openclaw-microvm;
in
{
  options.services.openclaw-microvm = {
    enable = mkEnableOption "OpenClaw in microVM";

    telegramBotToken = mkOption {
      type = types.str;
      description = "Path to Telegram bot token file";
    };

    openrouterApiKey = mkOption {
      type = types.str;
      description = "Path to OpenRouter API key file";
    };

    allowedTelegramUsers = mkOption {
      type = types.listOf types.int;
      default = [];
      description = "Telegram user IDs to allow";
    };
  };

  config = mkIf cfg.enable {
    # MicroVM host configuration
    microvm.vms.openclaw = {
      config = {
        imports = [ ../microvm/base.nix ];

        customModules.microvm-base = {
          enable = true;
          vmName = "openclaw";
          ipAddress = "192.168.83.2";
          vcpu = 2;
          memory = 2048;
        };

        # Install OpenClaw via Home Manager
        home-manager.users.openclaw = { pkgs, ... }: {
          imports = [ nix-openclaw.homeManagerModules.default ];

          programs.openclaw = {
            enable = true;

            settings = {
              gateway = {
                mode = "local";
                port = 18789;
                authTokenFile = "/run/secrets/gateway-token";
              };

              channels = {
                telegram = {
                  enabled = true;
                  botTokenFile = "/run/secrets/telegram-token";
                  dmPolicy = "allowlist";
                  allowFrom = cfg.allowedTelegramUsers;
                };
              };

              models = {
                default = "openrouter/anthropic/claude-sonnet-4";
                openrouter = {
                  apiKeyFile = "/run/secrets/openrouter-key";
                };
              };
            };
          };
        };

        users.users.openclaw = {
          isNormalUser = true;
          home = "/home/openclaw";
        };
      };
    };

    # Host-side networking
    networking.bridges.br-openclaw.interfaces = [];

    networking.interfaces.br-openclaw = {
      ipv4.addresses = [{
        address = "192.168.83.1";
        prefixLength = 24;
      }];
    };

    # NAT for VM internet access
    networking.nat = {
      enable = true;
      internalInterfaces = [ "br-openclaw" ];
      externalInterface = "ens3"; # Adjust for your interface
    };

    # DNS resolver with logging
    services.unbound = {
      enable = true;
      settings = {
        server = {
          interface = [ "192.168.83.1" ];
          access-control = [ "192.168.83.0/24 allow" ];
          log-queries = "yes";
          verbosity = 1;
        };
        forward-zone = [{
          name = ".";
          forward-addr = [ "1.1.1.1" "8.8.8.8" ];
        }];
      };
    };

    # nftables connection logging
    networking.nftables.tables.openclaw-monitor = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority 0; policy accept;

          # Log new connections from OpenClaw VM
          ip saddr 192.168.83.2 ct state new log prefix "openclaw-vm: "
        }
      '';
    };

    # Stage secrets for virtiofs mount
    systemd.tmpfiles.rules = [
      "d /run/openclaw-secrets 0700 root root -"
    ];

    systemd.services.openclaw-secrets-setup = {
      description = "Stage OpenClaw secrets for VM";
      wantedBy = [ "multi-user.target" ];
      before = [ "microvm@openclaw.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        cp ${cfg.telegramBotToken} /run/openclaw-secrets/telegram-token
        cp ${cfg.openrouterApiKey} /run/openclaw-secrets/openrouter-key

        # Generate gateway auth token if not exists
        if [ ! -f /run/openclaw-secrets/gateway-token ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > /run/openclaw-secrets/gateway-token
        fi

        chmod 400 /run/openclaw-secrets/*
      '';
    };
  };
}
```

### Step 4: Enable in Host Configuration

`hosts/sancta-choir/configuration.nix`:
```nix
{
  imports = [
    ../../modules/microvm/openclaw-vm.nix
  ];

  services.openclaw-microvm = {
    enable = true;
    telegramBotToken = config.age.secrets.telegram-bot-token.path;
    openrouterApiKey = config.age.secrets.openrouter-api-key.path;
    allowedTelegramUsers = [ 123456789 ]; # Your Telegram user ID
  };
}
```

## Network Monitoring

### DNS Query Logs
```bash
# View DNS queries from VM
journalctl -u unbound -f | grep "192.168.83.2"
```

### Connection Logs
```bash
# View outbound connections
journalctl -k | grep "openclaw-vm:"
```

### Expected Traffic
- `api.telegram.org` (Telegram Bot API)
- `openrouter.ai` (LLM API)
- DNS queries to `192.168.83.1`

## Testing

### 1. Start VM
```bash
systemctl start microvm@openclaw
systemctl status microvm@openclaw
```

### 2. Check VM Network
```bash
# From host
ping 192.168.83.2

# Access VM console
microvm-console openclaw
```

### 3. Test Telegram
1. Message your bot in Telegram
2. Check logs: `journalctl -u microvm@openclaw -f`
3. Verify DNS logs show Telegram API queries

### 4. Monitor Traffic
```bash
# Watch all VM traffic
tcpdump -i br-openclaw -n
```

## Migration from Current Setup

1. **Backup current OpenClaw data**:
   ```bash
   rsync -av /var/lib/openclaw/ /var/backups/openclaw-$(date +%Y%m%d)
   ```

2. **Disable old service**:
   ```nix
   services.openclaw.enable = false;
   ```

3. **Enable microVM**:
   ```nix
   services.openclaw-microvm.enable = true;
   ```

4. **Deploy**:
   ```bash
   nixos-rebuild switch --flake .#sancta-choir
   ```

## Advantages Over Current Setup

| Feature | Current (openclaw.nix) | MicroVM Approach |
|---------|------------------------|------------------|
| Isolation | nftables UID filter | Full VM kernel |
| Telegram | n8n workflows needed | Native grammY bot |
| Network monitoring | nftables logs only | DNS + connection logs |
| Attack surface | Host compromise possible | VM jail |
| Memory overhead | ~200MB | ~300MB (VM + OpenClaw) |
| Boot time | Instant | 3-5 seconds |
| Debugging | Easy (journalctl) | Harder (VM console) |

## Cost Considerations

- **Memory**: VM needs ~2GB RAM (current uses ~200MB)
- **CPU**: 2 vCPUs reserved for VM
- **Disk**: Minimal (shared Nix store)

**sancta-choir specs**: 4 vCPUs, 8GB RAM → Can afford it!

## Next Steps

- [ ] Add microvm.nix to flake inputs
- [ ] Add nix-openclaw to flake inputs
- [ ] Create base microVM module
- [ ] Create OpenClaw VM module
- [ ] Test on local VM first
- [ ] Deploy to sancta-choir
- [ ] Migrate Telegram bot token
- [ ] Test Telegram integration
- [ ] Monitor DNS/connection logs for 1 week
- [ ] Deprecate old openclaw.nix module
