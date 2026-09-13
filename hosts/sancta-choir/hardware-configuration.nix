{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.grub.device = "/dev/sda";
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "xen_blkfront" "vmw_pvscsi" ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };

  # Optional noncritical build staging volume. It is deliberately separate from
  # /nix and never formats or binds the Nix store. The build launch wrapper
  # must fail closed
  # when this mount is absent, while boot remains available with `nofail`.
  fileSystems."/mnt/sancta-build-volume" = {
    device = "/dev/disk/by-uuid/541b15e9-7c7c-4e4a-8efc-1eb5a3257f0f";
    fsType = "ext4";
    options = [ "nofail" "nodev" "nosuid" "noatime" "x-systemd.device-timeout=10s" ];
  };
}
