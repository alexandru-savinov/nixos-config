# Minimal hardware configuration for CI/testing
# Real hardware config is machine-specific and not committed
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.grub.device = "/dev/sda";
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_blk" ];

  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };
}
