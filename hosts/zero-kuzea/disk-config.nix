# Declarative disk layout for zero-kuzea (Hetzner CX22 VPS).
# Same layout as sancta-claw: BIOS boot + ESP + ext4 root.
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
                mountpoint = "/boot";
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
