# Shared secret helpers for age.secrets declarations.
# Usage:
#   let inherit (import ../../lib/secrets.nix { inherit self; }) secret ownedSecret; in
#   age.secrets = {
#     my-key = secret "my-key";                        # owner=root
#     kuzea-key = ownedSecret "openclaw" "kuzea-key";  # owner=openclaw
#   };
{ self }:

{
  # Simple secret — default owner (root:root, mode 0400)
  secret = name: {
    file = "${self}/secrets/${name}.age";
  };

  # Secret owned by a specific user/group (e.g. openclaw, nullclaw)
  ownedSecret = owner: name: {
    file = "${self}/secrets/${name}.age";
    inherit owner;
    group = owner;
  };
}
