# Zero_kuzea — Dedicated NullClaw bot on Hetzner CX22 VPS.
#
# Minimal NixOS host: Tailscale + NullClaw gateway + Telegram.
# Uses sancta-claw's stable age recovery key for secret decryption.
# Deploy via nixos-anywhere: see docs/DISASTER-RECOVERY.md
{ config
, lib
, self
, ...
}:
{
  imports = [
    ../common.nix
    ./hardware-configuration.nix
    ./disk-config.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/nullclaw.nix
    ../../modules/system/ssh-hardened.nix
  ];

  # ── System ───────────────────────────────────────────────────────────
  networking.hostName = "zero-kuzea";
  system.stateVersion = "25.05";

  # ── SSH authorized keys ─────────────────────────────────────────────
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPw5RFrFfZQUWlyfGSU1Q8BlEHnvIdBtcnCn+uYtEzal nixos-sancta-choir"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL2btaYomBlcKG+snrIrBuTXcEaBKEGQoAaF59YWwkal nixos@rpi5"
  ];

  # ── Agenix — stable age recovery key (same as sancta-claw) ──────────
  # Private key placed by nixos-anywhere --extra-files during deployment.
  # Stored on rpi5:/root/dr/recovery-sancta-claw.key + Bitwarden.
  age.identityPaths = [ "/root/.age/recovery.key" ];

  age.secrets =
    let
      inherit (import ../../lib/secrets.nix { inherit self; }) secret ownedSecret;
      nullclawSecret = ownedSecret "nullclaw";
    in
    {
      tailscale-auth-key = secret "tailscale-auth-key";
      anthropic-api-key = nullclawSecret "anthropic-api-key";
      zero-kuzea-telegram-bot-token = nullclawSecret "zero-kuzea-telegram-bot-token";
    };

  # ── NullClaw (Zero_kuzea bot) ───────────────────────────────────────
  services.nullclaw = {
    enable = true;
    provider = "anthropic";
    model = "claude-sonnet-4-6";
    apiKeyFile = config.age.secrets.anthropic-api-key.path;
    telegram = {
      botTokenFile = config.age.secrets.zero-kuzea-telegram-bot-token.path;
      allowedUsers = [ "364749075" ];
    };
    tailscaleServe.enable = true;
  };
}
