# Not imported by the active recipient registry or host configuration.
# From secrets/: RULES=./vigil-contracts.pending.nix agenix -e vigil-rpi5-contract-1.age
# Create all three ciphertexts, then promote these rules and host declarations
# together. Never commit plaintext contracts to this public repository.
let
  recipients = (import ./secrets.nix)."ha-vigil-token.age".publicKeys;
in
{
  "vigil-rpi5-contract-1.age".publicKeys = recipients;
  "vigil-rpi5-contract-2.age".publicKeys = recipients;
  "vigil-rpi5-contract-3.age".publicKeys = recipients;
}
