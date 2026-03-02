{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  # fileSystems managed by disko (see disk-config.nix)
  # Hetzner Cloud uses UEFI — install GRUB for both BIOS and EFI
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.efiInstallAsRemovable = true;
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "xen_blkfront"
    "vmw_pvscsi"
  ];
  boot.initrd.kernelModules = [ ];
}
