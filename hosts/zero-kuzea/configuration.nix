# Zero_kuzea — Dedicated NullClaw bot on Hetzner CX22 VPS.
#
# Minimal NixOS host: Tailscale + NullClaw gateway + Telegram.
# Uses sancta-claw's stable age recovery key for secret decryption.
# Deploy via nixos-anywhere: see docs/DISASTER-RECOVERY.md
{
  config,
  lib,
  self,
  ...
}:
{
  imports = [
    ../common.nix
    ./hardware-configuration.nix
    ./disk-config.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/nullclaw.nix
  ];

  # ── System ───────────────────────────────────────────────────────────
  networking.hostName = "zero-kuzea";
  system.stateVersion = lib.mkForce "25.05";

  # ── Agenix — stable age recovery key (same as sancta-claw) ──────────
  # Private key placed by nixos-anywhere --extra-files during deployment.
  # Stored on rpi5:/root/dr/recovery-sancta-claw.key + Bitwarden.
  age.identityPaths = [ "/root/.age/recovery.key" ];

  age.secrets = {
    tailscale-auth-key.file = "${self}/secrets/tailscale-auth-key.age";

    openrouter-api-key = {
      file = "${self}/secrets/openrouter-api-key.age";
      owner = "nullclaw";
      group = "nullclaw";
    };

    zero-kuzea-telegram-bot-token = {
      file = "${self}/secrets/zero-kuzea-telegram-bot-token.age";
      owner = "nullclaw";
      group = "nullclaw";
    };
  };

  # ── NullClaw (Zero_kuzea bot) ───────────────────────────────────────
  services.nullclaw = {
    enable = true;
    port = 18790;
    model = "anthropic/claude-sonnet-4-6";
    openrouterApiKeyFile = config.age.secrets.openrouter-api-key.path;
    telegram = {
      botTokenFile = config.age.secrets.zero-kuzea-telegram-bot-token.path;
      allowedUsers = [ "364749075" ];
    };
    tailscaleServe = {
      enable = true;
      httpsPort = 18790;
    };
  };
}
