# Declarative disk layout for sancta-claw (Hetzner CX33 VPS).
# Matches the existing partition table — disko will NOT reformat on rebuild.
#
# IMPORTANT: Before the first rebuild with disko, set GPT partition labels
# to match disko's expected names (non-destructive, no data loss):
#
#   sudo sgdisk \
#     --change-name=14:disk-sda-boot \
#     --change-name=15:disk-sda-ESP \
#     --change-name=1:disk-sda-root \
#     /dev/sda
#
# Without this, /dev/disk/by-partlabel/disk-sda-root won't exist and
# the system won't mount root on next boot.
{ ... }:
{
  disko.devices = {
    disk = {
      sda = {
        device = "/dev/sda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              type = "EF02";
              size = "1M";
              priority = 1;
            };
            ESP = {
              type = "EF00";
              size = "256M";
              priority = 2;
              content = {
                type = "filesystem";
                format = "vfat";
                # Not mounted — GRUB uses MBR/BIOS boot, not EFI
              };
            };
            root = {
              size = "100%";
              priority = 3;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
