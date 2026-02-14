# Official OpenClaw Telegram Integration

Based on [DeepWiki OpenClaw Documentation](https://deepwiki.com/openclaw/openclaw/8.5-telegram-integration)

## What is Official OpenClaw?

OpenClaw is an open-source personal AI agent that runs 24/7, communicates through WhatsApp/Telegram, maintains memory, and executes tasks on your machine. It's different from the custom `modules/services/openclaw.nix` in this repo (which is a Claude Code CLI wrapper).

## Installation

### 1. Install OpenClaw CLI

```bash
npm install -g openclaw@latest

# Verify installation
openclaw --version
```

### 2. Run Onboarding Wizard

```bash
openclaw onboard --install-daemon --flow quickstart
```

This sets up:
- Model provider (Anthropic/OpenAI)
- Gateway service (port 18789)
- Channel configuration
- System daemon (systemd on Linux)

## Telegram Setup

### Step 1: Create Telegram Bot

1. Message **@BotFather** on Telegram
2. Send: `/newbot`
3. Name: `My OpenClaw Assistant`
4. Username: `my_openclaw_bot` (must end in `bot`)
5. Copy the bot token: `123456789:ABCdefGHIjklmnoPQRstuvWXYZabcdefgh`

### Step 2: Configure OpenClaw

Edit OpenClaw's config file (usually `~/.openclaw/config.json` or set via wizard):

```json
{
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "YOUR_TELEGRAM_BOT_TOKEN",
      "dmPolicy": "pairing",
      "allowFrom": [],
      "mediaMaxMb": 5,
      "replyToMode": "first",
      "reactionNotifications": "own"
    }
  }
}
```

### Step 3: Set Environment Variable (Alternative)

```bash
export TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
openclaw gateway start
```

Environment variables override config file values.

### Step 4: Start the Gateway

```bash
openclaw gateway start

# Or run in foreground for testing
openclaw gateway start --verbose
```

## Access Control Modes

### DM Policy Options

#### 1. Pairing (Recommended)
```json
{
  "dmPolicy": "pairing"
}
```

Flow:
1. User sends message to bot
2. Bot generates 6-digit code
3. User approves via CLI: `openclaw telegram pair approve <code>`
4. User is permanently allowed

#### 2. Allowlist
```json
{
  "dmPolicy": "allowlist",
  "allowFrom": [123456789, "username"]
}
```

Only listed users/IDs can message the bot. No pairing option.

#### 3. Open (Insecure)
```json
{
  "dmPolicy": "open",
  "allowFrom": ["*"]
}
```

Anyone can message the bot. Use only for testing!

#### 4. Disabled
```json
{
  "dmPolicy": "disabled"
}
```

Ignores all direct messages.

## Group Chat Configuration

```json
{
  "channels": {
    "telegram": {
      "groups": {
        "-1001234567890": {
          "enabled": true,
          "requireMention": true,
          "mentionPatterns": ["@bot", "hey bot"],
          "topics": {
            "123": {
              "enabled": true,
              "requireMention": false
            }
          }
        },
        "*": {
          "enabled": true,
          "requireMention": true
        }
      }
    }
  }
}
```

**To get group chat ID:**
1. Add bot to group
2. Check logs: `openclaw gateway start --verbose`
3. Send a message in the group
4. Log shows chat ID like `-1001234567890`

## Webhook Mode (Production)

Default is polling mode (good for development). For production, use webhooks:

```json
{
  "channels": {
    "telegram": {
      "webhookUrl": "https://yourdomain.com/telegram",
      "webhookSecret": "your-secret-token-32-chars"
    }
  }
}
```

**Requirements:**
- Valid HTTPS certificate
- Public domain name
- Telegram will POST updates to your URL
- Gateway verifies `X-Telegram-Bot-Api-Secret-Token` header

## Native Commands

OpenClaw automatically registers Telegram commands:

```json
{
  "channels": {
    "telegram": {
      "customCommands": [
        { "name": "start", "description": "Begin interaction" },
        { "name": "help", "description": "Show help" },
        { "name": "status", "description": "Check bot status" }
      ]
    }
  }
}
```

Users can type `/start`, `/help`, etc. in Telegram.

## CLI Integration

Send messages TO Telegram FROM CLI:

```bash
# Send to user by chat ID
openclaw agent send main --to "telegram:123456789" "Hello!"

# Send to group
openclaw agent send main --to "telegram:-1001234567890" "Group message"

# Send to forum topic
openclaw agent send main --to "telegram:-1001234567890:topic:123" "Topic reply"

# Send to username
openclaw agent send main --to "telegram:@username" "DM via username"
```

## Testing

### 1. Start Gateway
```bash
openclaw gateway start --verbose
```

### 2. Test DM Flow (with pairing)

**In Telegram:**
```
You: Hello bot!
Bot: Pairing request from @yourname (code: 123456)
```

**In terminal:**
```bash
openclaw telegram pair approve 123456
```

**In Telegram:**
```
Bot: Hello! How can I help you today?
```

### 3. Test Group Chat

1. Add bot to group
2. Send: `@my_openclaw_bot what's the weather?`
3. Bot responds to mentions only (if `requireMention: true`)

## NixOS Integration

### Option A: NPM Global Install (Simple)

```nix
{
  environment.systemPackages = with pkgs; [
    nodejs_22
    # Then: npm install -g openclaw
  ];
}
```

### Option B: Custom NixOS Module (Advanced)

Create `modules/services/official-openclaw.nix`:

```nix
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.official-openclaw;
  configFile = pkgs.writeText "openclaw-config.json" (builtins.toJSON cfg.config);
in
{
  options.services.official-openclaw = {
    enable = mkEnableOption "Official OpenClaw AI agent";

    package = mkOption {
      type = types.package;
      default = pkgs.buildNpmPackage {
        pname = "openclaw";
        version = "latest";
        # ... npm package build
      };
      description = "OpenClaw package";
    };

    config = mkOption {
      type = types.attrs;
      default = {};
      description = "OpenClaw configuration (config.json)";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.openclaw-gateway = {
      description = "OpenClaw AI Gateway";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/openclaw gateway start --config ${configFile}";
        Restart = "always";
        User = "openclaw";
        Group = "openclaw";
      };
    };

    users.users.openclaw = {
      isSystemUser = true;
      group = "openclaw";
    };

    users.groups.openclaw = {};
  };
}
```

Then in `hosts/sancta-choir/configuration.nix`:

```nix
{
  services.official-openclaw = {
    enable = true;
    config = {
      channels = {
        telegram = {
          enabled = true;
          botToken = "YOUR_TOKEN";
          dmPolicy = "pairing";
        };
      };
    };
  };
}
```

## Comparison: Official OpenClaw vs Custom openclaw.nix

| Feature | Official OpenClaw | Custom openclaw.nix |
|---------|------------------|---------------------|
| Implementation | Node.js service (grammY) | Claude Code CLI wrapper |
| Telegram | Native bot integration | Requires n8n workflow |
| Channels | WhatsApp, Discord, Slack | File-based inbox only |
| Session memory | Built-in persistent | No memory |
| Commands | Native `/commands` | Manual task files |
| Real-time | WebSocket/polling | Batch processing |
| Tools | File ops, shell, MCP | Git, nix, gh only |

## Troubleshooting

### Bot doesn't respond

```bash
# Check gateway status
openclaw gateway status

# View logs
journalctl -u openclaw-gateway -f

# Test with verbose output
openclaw gateway start --verbose
```

### Pairing code not working

```bash
# List pending pairing requests
openclaw telegram pair list

# Manually approve by chat ID
openclaw telegram pair approve <code>
```

### Webhook errors

```bash
# Check webhook status
curl "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo"

# Delete webhook and use polling
curl -X POST "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook"
```

## Resources

- **Official Documentation**: [DeepWiki OpenClaw](https://deepwiki.com/openclaw/openclaw)
- **Telegram Integration**: [8.5 Telegram Integration](https://deepwiki.com/openclaw/openclaw/8.5-telegram-integration)
- **GitHub**: [openclaw/openclaw](https://github.com/openclaw/openclaw)
- **Quick Start**: [1.2 Quick Start](https://deepwiki.com/openclaw/openclaw/1.2-quick-start)

## Next Steps

- [ ] Install OpenClaw: `npm install -g openclaw@latest`
- [ ] Run onboarding: `openclaw onboard --flow quickstart`
- [ ] Create Telegram bot via @BotFather
- [ ] Configure Telegram channel in OpenClaw config
- [ ] Start gateway: `openclaw gateway start`
- [ ] Test DM flow with pairing
- [ ] (Optional) Create NixOS module for declarative config
