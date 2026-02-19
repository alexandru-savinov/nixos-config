# Disko disk configuration for Hetzner Cloud VPS
# GPT partition table with BIOS boot + ext4 root on /dev/sda
#
# Used by nixos-anywhere for automated disk partitioning.
# Existing instances (sancta-choir, sancta-kuzea) don't need this —
# they already have partitioned disks and use fileSystems from hetzner-cloud.nix.

{ ... }:

{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        # BIOS boot partition (required for GRUB on GPT)
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot
        };
        # Root filesystem
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
