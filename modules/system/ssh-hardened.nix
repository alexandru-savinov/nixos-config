# SSH hardening for VPS hosts.
# Import this in hosts that should disable password auth and restrict root login.
# RPi5 base keeps bootstrap-friendly defaults (PasswordAuthentication = mkDefault true).
{ ... }:

{
  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
  };
}
