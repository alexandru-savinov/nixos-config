---
name: verify-first
description: Force a hypothesis-verify step before applying any fix. Use when diagnosing bugs, NixOS build failures, service errors, or any problem where the root cause is not yet confirmed. Prevents wrong-approach detours by requiring a testable hypothesis before touching any code or config.
---

# Verify First

Before applying **any** fix, complete this protocol:

---

## The Protocol

### Step 1 — State the Hypothesis

Write one sentence: *"I believe the root cause is X because Y."*

- Be specific. Name the exact option, file, line, or behavior.
- If you have multiple candidates, rank them by likelihood. Start with the most likely.
- Do NOT proceed until you have a concrete hypothesis.

### Step 2 — Design a Minimal Test

Identify the smallest possible command or check that would **confirm or refute** your hypothesis **without making any changes**.

Good tests for NixOS:
```bash
grep -r "optionName" modules/                               # find where it's set (fast, no eval)
nix eval .#nixosConfigurations.rpi5-full.config.<option>   # inspect current value
nix repl .#  # interactive flake exploration
nixos-rebuild dry-build --flake .#rpi5-full 2>&1 | grep -iE "warn|error"  # capture current warnings/errors
```

Good tests for services:
```bash
journalctl -u <service> -n 50    # recent logs
systemctl status <service>       # current state
```

If no minimal test exists, say so explicitly and explain why before proceeding.

### Step 3 — Run the Test

Run it. Show the output.

- If the output **confirms** your hypothesis → proceed to Step 4.
- If the output **refutes** your hypothesis → return to Step 1 with a revised hypothesis. Do NOT apply the fix anyway.

### Step 4 — Apply the Fix

Only now make the change. Keep it minimal — fix exactly what the hypothesis identified, nothing more.

### Step 5 — Verify the Fix

Re-run the same test from Step 2 (or an equivalent) to confirm:
- The original problem is gone.
- No new warnings or errors were introduced.

For NixOS changes, always run:
```bash
nixos-rebuild dry-build --flake .#rpi5-full 2>&1 | grep -iE "warn|error"
```

If the fix introduced new issues, **revert it**, update your hypothesis, and restart from Step 1.

---

## Anti-Patterns to Avoid

| Don't | Why |
|-------|-----|
| Apply a fix that "seems right" without testing | Root cause may be different; fix may worsen the problem |
| Use `2>/dev/null` to suppress errors silently | Hides real problems, masks wrong hypotheses |
| Fix multiple things at once | Can't tell which change caused which effect |
| Skip Step 5 after applying the fix | Fix may have worked but introduced regressions |
| Guess at NixOS option names without checking | Option names change between versions; always verify with `nix eval` or docs |

---

## NixOS-Specific Checklist

Before changing any NixOS option:

- [ ] Run `nixos-rebuild dry-build --flake .#rpi5-full` and capture current warnings/errors
- [ ] Confirm which module sets the option causing the issue (use `grep -r` or `nix eval`)
- [ ] Verify the option exists: `nix eval .#nixosConfigurations.rpi5-full.config.<option>` (eval error = option does not exist)
- [ ] After the change, re-run `nixos-rebuild dry-build --flake .#rpi5-full` and diff the output

---

## Example (Good)

> **Hypothesis:** The Home Manager warning about `useGlobalPkgs` is caused by the option being explicitly set to `true` in `hosts/rpi5/configuration.nix`, which triggers a warning in this version of Home Manager.
>
> **Test:** `grep -r "useGlobalPkgs" .`
>
> **Output:** Found in `hosts/rpi5/configuration.nix:60: useGlobalPkgs = true;`
>
> **Confirmed.** Removing that line should resolve the warning.
>
> **Fix:** Remove line 60.
>
> **Verify:** Re-run `nixos-rebuild dry-build --flake .#rpi5-full`. Warning is gone.

## Example (Bad — do not do this)

> The warning mentions `useGlobalPkgs` so I'll set it to `false` to suppress it.
> *(No test, no confirmation, wrong fix — this was actually the cause, not the cure.)*
