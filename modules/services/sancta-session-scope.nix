{ pkgs, ... }:

{
  # Supply the drop-in through the generated systemd user-unit tree. A nested
  # environment.etc entry would collide with NixOS's /etc/systemd/user symlink.
  # Dash-prefix matching covers current and recovered sancta-* backends.
  systemd.packages = [
    (pkgs.writeTextDir "lib/systemd/user/agt-mvp-sancta-.scope.d/50-resource-policy.conf" ''
      [Scope]
      MemoryHigh=4G
      MemoryMax=5G
      MemorySwapMax=2G
      OOMPolicy=continue
      TimeoutStopSec=45
    '')
  ];
}
