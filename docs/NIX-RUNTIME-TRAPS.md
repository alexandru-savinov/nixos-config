# Nix packaging traps that build clean but break at runtime

Catalogue from the 501-commit retrospective (#454/#452). Everything here
passed `nix flake check` and a full build, then failed when the service
actually ran. Check this list before packaging anything Node/Chromium-shaped.

## 1. pnpm: `cp -r`, never `cp -rL`

pnpm's virtual store makes `node_modules` a tree of **relative symlinks**
into `.pnpm`. `cp -rL` dereferences them, which breaks Node's transitive
dependency resolution (Node traverses the *real* path, so
`.pnpm/<pkg>/node_modules/<dep>` is never consulted — `jszip` became
unreachable). Use `cp -r` for anything that came out of a pnpm install, in
every derivation that copies it (`dbceeee`; latent recurrence fixed in
`hosts/sancta-claw/openclaw-service.nix:105`, #452).

## 2. Playwright/Chromium: point at the nix browser, never self-download

- Plain CLI use: set `PLAYWRIGHT_BROWSERS_PATH` and
  `PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS` (`fd944e7`).
- Bundled `playwright-core` expecting a different Chromium revision than
  nixpkgs ships: use a **direct executable-path override**
  (`AGENT_BROWSER_EXECUTABLE_PATH`, `dbceeee`) and pin the revision from the
  pure attrset `pkgs.playwright-driver.browsersJSON."chromium-headless-shell".revision`.
- Never pin via `builtins.readDir` store scans (IFD-like, can silently
  return empty — `7e269bb`) and never hardcode revision numbers (they are
  point-in-time; the `browsersJSON` pin is what stays correct).

## 3. systemd hardening vs Chromium

- `PrivateDevices=true` strips `/dev/shm`, which Chromium needs for
  renderer↔browser IPC → re-add with `BindPaths = [ "/dev/shm" ]`
  (`c6db6c8`/#304).
- `noSandbox = true` is required for **two** reasons: the service user lacks
  `CAP_SYS_ADMIN`, *and* the setuid `chrome-sandbox` helper does not exist
  in the nix store (`8c9691d`, rationale `9acc88b`).

## 4. `with pkgs;` silently shadowed by flake-input names

In `with pkgs; [ agenix ]`, a flake input named `agenix` (a lambda argument)
wins over `pkgs.agenix` — Nix's `with` has *lower* precedence than lexical
bindings. The list element evaluates to the input's lambda/attrset, installs
nothing, and produces **no eval error**. Use the explicit form
(`agenix.packages.${pkgs.system}.default`) or avoid `with pkgs;` where a
flake input shares a package name (`f1b91bc`/#312). This was latent from the
first appearance — no overlay ever masked it.

## Related drift trap (watch, not fixed here)

`pnpmDeps` fixed-output hash + `fetcherVersion` in
`hosts/sancta-claw/openclaw-service.nix` only fails in the CI x86_64 build
after nixpkgs bumps (cf. #443 for the crates.io analogue).
