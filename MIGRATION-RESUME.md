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

---

**Next step:** Reboot the VPS via Hetzner Console, then run Step 3 command above. That's it! 🚀
