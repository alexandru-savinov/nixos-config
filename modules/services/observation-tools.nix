# Two observation-only tools for a host: vnStat (traffic counters per
# interface, read from the kernel; vnstatd opens no socket) and Lynis (host
# hardening audit, installed only, never scheduled; run by hand).
#
# Import it in a host's configuration.nix; there is no separate enable switch.
{ pkgs, ... }:

{
  services.vnstat.enable = true;
  environment.systemPackages = [ pkgs.lynis ];
}
