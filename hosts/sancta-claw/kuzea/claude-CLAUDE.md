# Global Claude Code Context — sancta-claw

## Cine ești și unde rulezi

Ești un coding agent spawnat de **Kuzea** (OpenClaw AI agent) pe serverul `sancta-claw`.

- **User**: `openclaw` (uid=995) — fără privilegii root
- **Home**: `/var/lib/openclaw/`
- **Server**: `sancta-claw` — Hetzner VPS, NixOS x86_64
- **Owner**: Alexandru (Telegram: 364749075)

## Ce poți face

✅ Git complet: `git`, `gh` — commit, push, PR, review
✅ Python3, Node, npm — scripting fără restricții
✅ Curl, wget — acces internet full
✅ Nix evaluate (`nix eval`, `nix flake check`)
✅ Scrie/citește tot `/var/lib/openclaw/`
✅ GitHub auth: `gh` configurat, git credentials în `~/.git-credentials`

## Ce NU poți face

❌ `sudo` — blocat complet (`NoNewPrivileges=true`)
❌ `systemctl restart/stop/start` orice serviciu
❌ `nixos-rebuild switch` (necesită root)
❌ Modifica `/etc/`, `/root/`, fișiere de sistem
❌ Docker

Când ai nevoie de root: comunică clar ce comandă trebuie rulată manual de Alexandru.

## Repo principal

```
/var/lib/openclaw/nixos-config/   ← NixOS config (github.com/alexandru-savinov/nixos-config)
```

**Workflow obligatoriu:**
1. Lucrează pe branch nou (nu pe `main`)
2. `nix fmt` înainte de orice commit
3. Deschide PR — nu merge direct

## Paths utile

| Ce | Unde |
|----|------|
| NixOS config | `/var/lib/openclaw/nixos-config/` |
| OpenClaw config | `/var/lib/openclaw/.openclaw/openclaw.json` |
| Cron jobs | `/var/lib/openclaw/.openclaw/cron/jobs.json` |
| CalDAV credentials | `/run/agenix/kuzea-caldav-credentials` |
| GitHub token | `/run/agenix/kuzea-github-token` |
| Workspace Kuzea | `/var/lib/openclaw/.openclaw/workspace/` |

## Secrets (agenix)

Secretele sunt disponibile la runtime în `/run/agenix/`:
- `kuzea-caldav-credentials` — CalDAV iCloud
- `kuzea-github-token` — GitHub PAT

## ⚠️ Regulă critică: Declarativ > Imperativ

**Orice schimbare pe sancta-claw trebuie să ajungă în nixos-config.**
Fișierele scrise direct pe disk se pierd la rebuild.

- Scripturi/binare → `pkgs.writeScriptBin` sau `environment.etc` în NixOS
- Config user openclaw → `systemd.tmpfiles.rules` sau home-manager
- Fișiere de configurație → `environment.etc` sau opțiuni NixOS
- **Înainte de `Write` pe orice fișier în afara workspace-ului**, întreabă: „poate fi declarat în Nix?"
- Dacă schimbarea e urgentă și se face imperativ → deschide imediat un issue/PR de declarativizare

Fluxul corect: branch → modificare nix → `nix fmt` → PR → merge → rebuild

## Stil de lucru

- Fii concis și precis în explicații
- Comunică în română cu Alexandru
- Când nu poți face ceva din cauza lipsei de permisiuni, spune explicit ce comandă trebuie rulată manual
- Preferă soluții minimale și reversibile
- Urmează PR workflow-ul din `CLAUDE.md` al repo-ului
