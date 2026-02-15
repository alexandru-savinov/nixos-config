# sancta-kuzea Migration - Resume Instructions

**Status:** 95% Complete - Blocked by VPS reboot
**Date:** 2026-02-15 02:00 EET
**Elapsed Time:** 2.5 hours

## ⚠️ Current Situation

The migration is **almost complete** but the sancta-choir VPS **crashed** during the final bug fix deployment due to running out of memory while building `open-webui-frontend-0.7.1`.

**VPS Status:** Down (100% packet loss to 100.77.249.31)
**Last Known State:** Code successfully pulled (commit a4e1696), build in progress

## ✅ What's Been Accomplished

### Phase 1: Configuration Created (Tasks 1-4) ✅
- Created `hosts/sancta-kuzea/configuration.nix` (minimal, OpenClaw-only)
- Created `modules/services/openclaw-container.nix` (systemd-nspawn + nftables)
- Updated `secrets/secrets.nix` (sancta-choir → sancta-kuzea, same SSH key)
- Updated `flake.nix` (added sancta-kuzea configuration)
- **All changes merged:** PRs #247, #248, #249

### Phase 2: Initial Deployment (Task 6) ✅
- Deployed sancta-kuzea config to sancta-choir VPS
- Container `openclaw` started successfully
- Hostname maintained as "sancta-choir" (for seamless Tailscale access)

### Phase 3: Bug Fixes (Task 7) ✅
Identified and fixed 3 critical bugs:

1. **ExecStartPre PATH bug:** Commands in openclaw-git-setup.service used relative paths
   - **Fix:** Changed to absolute paths (`${pkgs.coreutils}/bin/mkdir`, etc.)

2. **Read-only mount conflict:** Git setup tried to write to read-only `/var/lib/openclaw`
   - **Fix:** Added check to skip git config if .gitconfig is read-only

3. **Missing default gateway:** Container had no route to internet
   - **Fix:** Added `networking.defaultGateway = "192.168.84.1"` to container config

**All fixes committed and ready to deploy.**

## 🚨 Action Required: Reboot VPS

### Step 1: Access Hetzner Cloud Console
1. Go to https://console.hetzner.cloud/
2. Select your project
3. Find **sancta-choir** VPS
4. Click **Power** → **Reset** (force reboot)

### Step 2: Wait for VPS to Boot
```bash
# Test connectivity (from rpi5)
ping -c 3 sancta-choir.tail4249a9.ts.net
# OR
ping -c 3 100.77.249.31

# Once responsive, test SSH
ssh root@sancta-choir.tail4249a9.ts.net "echo 'VPS is back!'"
```

### Step 3: Complete Deployment (Single Command)

Once VPS is online, run this command to finish everything:

```bash
ssh root@sancta-choir.tail4249a9.ts.net "
  cd /root/nixos-config &&
  nixos-rebuild switch --flake .#sancta-kuzea --max-jobs 1 --cores 1 &&
  echo '=== Verifying OpenClaw Container ===' &&
  machinectl list &&
  systemctl status container@openclaw --no-pager &&
  machinectl shell openclaw systemctl status openclaw --no-pager &&
  echo '=== Testing Network Isolation ===' &&
  machinectl shell openclaw ping -c 2 8.8.8.8 &&
  echo '✅ Migration Phase 1 Complete!'"
```

**What this does:**
- Redeploys with bug fixes (using memory limits to prevent OOM)
- Verifies container is running
- Checks OpenClaw service status
- Tests network connectivity
- Reports success

**Expected output:**
- Container `openclaw` shows as running
- OpenClaw services active
- Ping to 8.8.8.8 succeeds

## 📋 Remaining Tasks (Optional)

### Task 8: Change Hostname to sancta-kuzea

**Current state:** Hostname is still "sancta-choir" (maintains Tailscale access)

**To change hostname:**

1. Edit the configuration:
```bash
cd ~/nixos-config
git checkout -b feat/kuzea-hostname-change

# Edit hosts/sancta-kuzea/configuration.nix
# Change line 40 from:
networking.hostName = "sancta-choir";
# To:
networking.hostName = "sancta-kuzea";

git add hosts/sancta-kuzea/configuration.nix
git commit -m "feat(sancta-kuzea): change hostname from choir to kuzea"
git push -u origin feat/kuzea-hostname-change

gh pr create --title "Change hostname to sancta-kuzea" --body "Completes migration by updating hostname from sancta-choir to sancta-kuzea"
gh pr merge --squash --delete-branch
git checkout main && git pull
```

2. Deploy hostname change:
```bash
ssh root@100.77.249.31 "cd /root/nixos-config && git pull && nixos-rebuild switch --flake .#sancta-kuzea"
```

3. Verify new hostname:
```bash
# Wait 30 seconds for Tailscale DNS propagation
sleep 30

# Connect via new hostname
ssh root@sancta-kuzea.tail4249a9.ts.net "hostname"
# Should output: sancta-kuzea

tailscale status | grep kuzea
# Should show: sancta-kuzea
```

### Task 9: Final Cleanup

**Update documentation:**
- CLAUDE.md: Update references from sancta-choir to sancta-kuzea
- This migration doc: Mark as complete

**Optional: Remove old sancta-choir config**
- Can keep in flake.nix (commented) for reference/rollback
- Or remove entirely if confident in new setup

## 🎯 Success Criteria

- [x] sancta-kuzea configuration created
- [x] All code committed and merged
- [x] Bug fixes applied
- [ ] VPS rebooted and accessible
- [ ] Configuration deployed successfully
- [ ] OpenClaw container running
- [ ] Network isolation working
- [ ] Hostname changed to sancta-kuzea (optional)
- [ ] Documentation updated (optional)

## 📊 Time Breakdown

| Phase | Duration | Status |
|-------|----------|--------|
| Config creation & commits | 30 min | ✅ Done |
| Initial deployment | 30 min | ✅ Done |
| Bug discovery & fixes | 1.5 hours | ✅ Done |
| Validation | 10 min | ✅ Done |
| **VPS reboot** | **5 min** | **⏳ Pending** |
| Bug fix deployment | 10 min | ⏳ Pending |
| Hostname change | 5 min | ⏳ Optional |
| Final cleanup | 5 min | ⏳ Optional |

**Total invested:** 2.5 hours
**Remaining:** 10-20 minutes after reboot

## 🔄 Rollback Procedure (If Needed)

If anything goes wrong after reboot:

```bash
# Quick rollback to previous generation
ssh root@sancta-choir.tail4249a9.ts.net "nixos-rebuild switch --rollback"

# Full rollback to original sancta-choir config
ssh root@sancta-choir.tail4249a9.ts.net "
  cd /root/nixos-config &&
  nixos-rebuild switch --flake .#sancta-choir"
```

## 📝 Technical Notes

**Why VPS crashed:**
- 4GB VPS ran out of memory during parallel build
- Building open-webui-frontend (Node.js/npm) is memory-intensive
- No swap space configured
- Solution: `--max-jobs 1 --cores 1` limits parallelism

**Network Architecture:**
- Container: 192.168.84.2/24
- Host bridge: 192.168.84.1/24 (cnt-openclaw)
- NAT: Container → eth0 (host)
- nftables: Default drop, whitelist Anthropic + GitHub only

**Container Bind Mounts:**
- `/var/lib/openclaw` (ro) - Git repository
- `/var/lib/openclaw/results` (rw) - Task outputs
- `/run/secrets` (ro) - Staged secrets from host

## 🔥 LESSONS LEARNED - Boot Failure Incident (Feb 15, 2026)

### What Happened

**Incident:** VPS completely unbootable after failed `nixos-rebuild switch`
**Duration:** ~10 hours to diagnose and repair
**Root Cause:** `nixos-rebuild switch` updated bootloader BEFORE build completed

### The Failure Chain

1. ❌ **OOM during build** → Node.js build consumed all 4GB RAM
2. ❌ **Bootloader updated anyway** → GRUB pointed to non-existent store path
3. ❌ **Kernel panic on boot** → "stage 2 init script not found"
4. ❌ **All generations inaccessible** → Default entry broken, no time to select from menu
5. ✅ **Rescue mode repair** → Manually fixed GRUB to boot generation 100

### Critical Insight: nixos-rebuild switch Is NOT Atomic

```
WHAT ACTUALLY HAPPENS:
1. Build new system          → CAN FAIL (OOM, network, etc)
2. Update GRUB bootloader    → RUNS REGARDLESS (DANGEROUS!)
3. Activate services         → Never reached if build fails

Result: Bootloader corruption if build fails mid-way
```

**Why this is dangerous on remote VPS:**
- Can't access GRUB menu to select old generation (web console timeout)
- Can't see error messages (no physical display)
- Must use rescue mode (slow, requires provider access)

### 🔴 CRITICAL: Never Do This Again

```bash
# ❌ DANGEROUS on remote VPS with risky configs:
nixos-rebuild switch --flake .#new-config

# ✅ SAFE - Test build first:
nixos-rebuild build --flake .#new-config --max-jobs 1 --cores 1
# If build succeeds, THEN switch:
nixos-rebuild switch --flake .#new-config
```

### 🟡 Required Safety Measures for Remote VPS Deployments

#### 1. **Always Use Memory Limits** (Prevents OOM)
```bash
nixos-rebuild switch --flake .#config --max-jobs 1 --cores 1
```

#### 2. **Test Build Before Switch** (Prevents Bootloader Corruption)
```bash
# Step 1: Build only (no system changes)
ssh root@vps "nixos-rebuild build --flake .#config --max-jobs 1 --cores 1"

# Step 2: If build succeeds, switch
ssh root@vps "nixos-rebuild switch --flake .#config"
```

#### 3. **Use 'boot' for Risky Changes** (Safer Than 'switch')
```bash
# Updates bootloader but requires manual reboot to activate
nixos-rebuild boot --flake .#config --max-jobs 1 --cores 1
# Then verify system boots before making it permanent
```

#### 4. **Add Swap Space** (Buffer for Memory Spikes)
```nix
# In configuration.nix:
swapDevices = [ { device = "/swapfile"; size = 2048; } ];  # 2GB swap
```

#### 5. **Keep Rescue Credentials Handy**
- Hetzner Console: https://console.hetzner.cloud/
- Know how to enable rescue mode
- Have diagnostic scripts ready

### Recovery Procedure (If Boot Fails Again)

**If VPS becomes unbootable after deployment:**

1. **Enable Hetzner Rescue Mode**
   - Console → Server → Rescue → Enable & Reboot
   - Note IP and password

2. **Install sshpass** (if connecting remotely)
   ```bash
   apt-get update && apt-get install -y sshpass
   ```

3. **Run Diagnostics**
   ```bash
   mount /dev/sda1 /mnt
   ls -la /mnt/nix/var/nix/profiles/system-*-link  # Check generations
   readlink /mnt/nix/var/nix/profiles/system       # Current generation
   cat /mnt/boot/grub/grub.cfg | grep menuentry    # Bootloader config
   ```

4. **Fix GRUB** (point to last working generation)
   ```bash
   cp /mnt/boot/grub/grub.cfg /mnt/boot/grub/grub.cfg.backup
   # Edit grub.cfg to use working generation's store path
   # (See detailed commands in incident notes)
   ```

5. **Unmount and Reboot**
   ```bash
   umount /mnt
   # Exit rescue mode via Hetzner Console
   ```

### Why Memory Limits Are Non-Negotiable

| Build Type | Memory Usage | 4GB VPS Without Limits | With --max-jobs 1 --cores 1 |
|------------|--------------|----------------------|---------------------------|
| Node.js/npm (open-webui) | ~1.5GB per job | 4 parallel jobs = **6GB** ❌ OOM | 1 job = 1.5GB ✅ Safe |
| Rust compilation | ~1GB per job | 4 parallel jobs = **4GB** ⚠️ Risky | 1 job = 1GB ✅ Safe |
| Python packages | ~500MB per job | Usually safe | Always safe |

**Rule of thumb:** If VPS has <8GB RAM, ALWAYS use `--max-jobs 1 --cores 1`

### Prevention Checklist for Future Deployments

Before running `nixos-rebuild switch` on remote VPS:

- [ ] Swap space configured (`swapDevices`)
- [ ] Memory limits specified (`--max-jobs 1 --cores 1`)
- [ ] Build tested locally or in CI
- [ ] OR: Build tested on VPS with `nixos-rebuild build` first
- [ ] Rescue mode credentials accessible
- [ ] Time allocated for recovery if needed (not deploying before sleep!)

### The One-Liner That Prevents 99% of Boot Failures

```bash
# Always use this pattern for remote VPS deployments:
ssh root@vps "nixos-rebuild build --flake .#config --max-jobs 1 --cores 1 && nixos-rebuild switch --flake .#config"
#              ^^^^^^^^^^^^^ TEST BUILD FIRST ^^^^^^^^^^^^^     ^^^ Only switch if build succeeds ^^^
```

---

**Next step:** Reboot the VPS via Hetzner Console, then run Step 3 command above (which now includes `--max-jobs 1 --cores 1`). That's it! 🚀
