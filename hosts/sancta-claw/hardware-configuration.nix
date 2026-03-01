{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  # boot.loader.grub and fileSystems are managed by disko (see disk-config.nix)
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "xen_blkfront" "vmw_pvscsi" ];
  boot.initrd.kernelModules = [ ]; # sda/VirtIO disk, no NVMe needed
}
