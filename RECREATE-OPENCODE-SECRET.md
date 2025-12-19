# Recreating the Missing OpenCode API Key Secret

## Issue
The `opencode-api-key.age` file is missing from the repository, which is referenced in the NixOS configuration but doesn't exist in the secrets directory.

## Solution
To properly recreate this secret, follow these steps:

### 1. Generate or obtain the OpenCode API key
First, you need to obtain the actual API key that should be used for the OpenCode service.

### 2. Navigate to the secrets directory
```bash
cd /path/to/nixos-config/secrets
```

### 3. Use agenix to create the encrypted secret
```bash
agenix -e opencode-api-key.age
```

### 4. Enter the API key
Paste the API key into the editor that opens, save and exit.

### 5. Commit the new secret
```bash
git add opencode-api-key.age
git commit -m "Add missing opencode-api-key secret"
```

### 6. Re-enable the secret in configuration
Uncomment the line in `hosts/sancta-choir/configuration.nix`:
```
opencode-api-key.file = "${self}/secrets/opencode-api-key.age";
```

### 7. Rebuild the system
```bash
sudo nixos-rebuild switch --flake .#sancta-choir
```

This will properly integrate the secret into your NixOS configuration.