# The ONE fact both hosts read about the studio n8n on sancta-choir (sq085):
# is it on? Imported by hosts/sancta-choir/n8n.nix (choir sets
# sancta.studio.n8n.enable from it) and by hosts/rpi5-full (the Gatus
# dashboard shows choir-vigil-n8n under it). A tiny shared module instead of
# rpi5-full cross-evaluating self.nixosConfigurations.sancta-choir, so an
# eval error anywhere in choir's module tree can never break an rpi5-full
# build (PR #622 review).
#
# Flip it HERE (default below), after secrets/n8n-encryption-key-choir.age
# exists — see the steps in ./n8n.nix. Both hosts follow the same flip.
{ lib, ... }:
{
  options.sancta.studio.n8n.onChoir = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Whether the studio n8n runs on sancta-choir. Shared by sancta-choir
      (enables it) and rpi5-full (shows its Vigil contract on Gatus).
    '';
  };
}
