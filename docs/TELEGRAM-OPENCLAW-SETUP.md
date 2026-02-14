# Telegram → OpenClaw Integration Setup

This guide walks you through setting up a Telegram bot that communicates with OpenClaw for AI-assisted NixOS configuration management.

## Architecture

```
User (Telegram) → Telegram Bot API → n8n Webhook → SSH to sancta-choir
                                                   ↓
                                         OpenClaw Inbox (/var/lib/openclaw/inbox/)
                                                   ↓
                                         Claude Code processes task
                                                   ↓
                                         Results → /var/lib/openclaw/results/
                                                   ↓
                                         n8n polls results → Telegram message
```

## Prerequisites

- Telegram account
- Access to sancta-choir (Hetzner VPS where OpenClaw runs)
- n8n running on rpi5 with Tailscale HTTPS access

## Step 1: Create Telegram Bot

1. Open Telegram and search for `@BotFather`
2. Send: `/newbot`
3. Choose a name: `OpenClaw Assistant`
4. Choose a username: `openclaw_assistant_bot` (must end in `bot`)
5. Copy the API token (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

## Step 2: Add Telegram Token as Secret

```bash
cd ~/nixos-config/secrets

# Create the secret (replace with your actual token)
echo -n "YOUR_TELEGRAM_BOT_TOKEN" | agenix -e telegram-bot-token.age

# Add to secrets.nix
```

Edit `secrets/secrets.nix` and add:

```nix
  telegram-bot-token.file = ./telegram-bot-token.age;
```

Then in `hosts/rpi5-full/configuration.nix`, add:

```nix
  age.secrets.telegram-bot-token.file = "${self}/secrets/telegram-bot-token.age";
```

## Step 3: Configure n8n Credentials

### Option A: Via n8n UI (Recommended for first setup)

1. Access n8n: `https://rpi5.tail4249a9.ts.net:5678`
2. Go to **Credentials** → **Add Credential**
3. Search for "Telegram API"
4. Name it: `Telegram Bot API`
5. Paste your bot token
6. Click **Save**

### Option B: Declarative (Future - requires n8n credentials feature)

Create `n8n-workflows/credentials.json`:

```json
{
  "telegramApi": {
    "accessToken": "{{ env.TELEGRAM_BOT_TOKEN }}"
  },
  "sshPassword": {
    "host": "sancta-choir",
    "port": 22,
    "username": "root",
    "privateKey": "{{ env.SSH_PRIVATE_KEY }}"
  }
}
```

## Step 4: Import Workflows

The workflows are already in the repository:

- `n8n-workflows/telegram-openclaw-bridge.json` - Main bot logic
- `n8n-workflows/openclaw-results-to-telegram.json` - Results delivery

### Import via n8n UI:

1. Access n8n: `https://rpi5.tail4249a9.ts.net:5678`
2. Click **Workflows** → **Import**
3. Upload `telegram-openclaw-bridge.json`
4. Upload `openclaw-results-to-telegram.json`

### Or via CLI (if declarative import is configured):

```bash
n8n import:workflow --input=n8n-workflows/telegram-openclaw-bridge.json
n8n import:workflow --input=n8n-workflows/openclaw-results-to-telegram.json
```

## Step 5: Configure SSH Access to sancta-choir

### Generate SSH key for n8n (if not exists):

```bash
# On rpi5
sudo -u n8n ssh-keygen -t ed25519 -f /var/lib/n8n/.ssh/id_ed25519 -N ""

# Copy public key to sancta-choir
sudo -u n8n ssh-copy-id root@sancta-choir
```

### Add SSH credential in n8n:

1. **Credentials** → **Add Credential** → **SSH**
2. Name: `SSH sancta-choir`
3. Host: `sancta-choir`
4. Port: `22`
5. Username: `root`
6. Authentication: **Private Key**
7. Private Key: Paste contents of `/var/lib/n8n/.ssh/id_ed25519`
8. Click **Save**

## Step 6: Set Telegram Webhook

The Telegram Trigger node in n8n requires a webhook URL. Since your n8n is behind Tailscale:

### Get the webhook URL:

1. Open the `Telegram → OpenClaw Bridge` workflow in n8n
2. Click on the **Telegram Trigger** node
3. Look for the webhook URL (something like: `https://rpi5.tail4249a9.ts.net:5678/webhook-test/telegram-openclaw`)

### Set the webhook:

```bash
# Replace with your actual values
BOT_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"
WEBHOOK_URL="https://rpi5.tail4249a9.ts.net:5678/webhook/telegram-openclaw"

curl -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{\"url\": \"${WEBHOOK_URL}\"}"
```

**Important:** Telegram webhooks require HTTPS. Your Tailscale HTTPS URL should work, but Telegram must be able to reach it. If you're on a free Tailscale plan, you may need to use `tailscale funnel` instead of `serve`:

```bash
sudo tailscale funnel --bg --https 5678 http://127.0.0.1:5678
```

## Step 7: Activate Workflows

In n8n UI:

1. Open `Telegram → OpenClaw Bridge`
2. Click **Active** toggle (top right) → ON
3. Open `OpenClaw Results → Telegram`
4. Click **Active** toggle → ON

## Step 8: Test the Integration

1. Open Telegram
2. Search for your bot username (`@openclaw_assistant_bot`)
3. Send: `/help`
4. You should receive a help message!

5. Try a simple task:
   ```
   List the files in the nixos-config repository and report what you see.
   ```

6. You should receive:
   - ✅ Confirmation message with task ID
   - ⏳ "Processing..." message
   - After ~30-60 seconds: Result message with Claude's response

## Troubleshooting

### Webhook not receiving messages

```bash
# Check webhook status
curl "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo"

# Delete webhook and try again
curl -X POST "https://api.telegram.org/bot${BOT_TOKEN}/deleteWebhook"
```

### n8n workflow not triggering

```bash
# Check n8n logs
ssh rpi5 journalctl -u n8n.service -f

# Verify Tailscale Serve is configured
tailscale serve status
```

### SSH connection fails

```bash
# Test SSH manually
ssh root@sancta-choir "ls /var/lib/openclaw/inbox/"

# Check SSH keys
sudo -u n8n ssh -v root@sancta-choir
```

### Task submitted but no results

```bash
# Check OpenClaw logs on sancta-choir
ssh root@sancta-choir "journalctl -u openclaw-task-runner.service -f"

# Check task mapping file
ssh rpi5 "cat /var/lib/n8n/telegram-openclaw-tasks.json"
```

## Usage Examples

### Simple queries
```
What services are configured in the nixos-config?
```

### Code changes
```
Add a health check for the Telegram bot integration to Gatus configuration
```

### Bug fixes
```
Fix the issue where the OpenClaw task results are not being delivered to Telegram
```

### Complex tasks
```
Create a new NixOS module for monitoring disk space and send alerts when usage exceeds 80%
```

## Cost Considerations

- Each task costs approximately $0.15-0.50 USD (depends on complexity)
- Max budget per task: $5 USD (configured in OpenClaw)
- Failed tasks still incur API costs
- Monitor costs via OpenClaw result logs

## Security Notes

- Telegram bot token is stored in agenix (encrypted)
- SSH keys are managed by systemd DynamicUser
- OpenClaw runs with network restrictions (only Anthropic + GitHub)
- Tasks are isolated in separate systemd service executions
- Consider restricting bot access to specific Telegram user IDs

## Advanced: Restrict to Specific Users

Edit the workflow and add a filter node after Telegram Trigger:

```javascript
// In a Code node:
const allowedUsers = ['your_telegram_username'];
const username = $json.message.from.username;

if (!allowedUsers.includes(username)) {
  throw new Error('Unauthorized user');
}

return $input.all();
```

## Next Steps

- [ ] Add `/results <task-id>` command to query specific task results
- [ ] Add cost tracking and usage reports
- [ ] Implement queue status checking
- [ ] Add support for file uploads (e.g., "analyze this config file")
- [ ] Create Telegram inline keyboard for common tasks
