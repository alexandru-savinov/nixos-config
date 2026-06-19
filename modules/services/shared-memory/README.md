# Shared-memory commons (MVP)

A write-tolerant, single-owner memory store for a heterogeneous agent fleet
(Claude · Codex · Hermes · NullClaw · …). Memory and messaging share one substrate.

## Shape
- **server.js** — HTTP ingest on `rpi5:8730` (Tailscale). `POST /write` appends an
  immutable envelope to the inbox via **temp+rename**. Caps: 1 MiB soft (flagged) /
  20 MiB hard (413). `GET /view` (materialized) · `GET /healthz`. Auth = no-op-allow seam.
- **librarian.js** — the **sole DB writer**. Ingests inbox → SQLite-WAL (tolerant row
  `{id,agent,node,ts,kind,text,entities,blob,raw,meta,content_hash,status,confidence,
  to_addr,topic}`), dedups by `content_hash`, quarantines only empty files,
  materializes `view.json`. Accepts **bare files** — any dropped payload.
- **shared-memory.nix** — NixOS module: ingest service + librarian timer + inotify
  path unit + **tailnet-only** firewall + systemd hardening + dedicated user.
- **writer-curl.sh** / **writer-file.sh** — examples (cross-host curl · same-host bare
  drop, no libraries).

## Two write surfaces
- **PRIMARY (cross-host):** `POST /write` over Tailscale — curl is enough.
- **FALLBACK (same-host):** drop a file into `$stateDir/inbox/` — pure file IO.

The writer never needs to know the schema, the atomic convention, or the size
limits — the server and librarian own all of that.

## Locked decisions (2026-06-19)
host `rpi5:8730` · durability single-disk + git(index) · auth Tailscale node id +
age envelope (no-op-allow in MVP) · caps 1/5/20 MiB · retention forever · write-back
**alongside** existing memory (not replacing) · comms columns `to/topic` carved dormant.

## Future (icebox)
`to`/`topic` + a read/subscribe path turn this store into a fleet **comms bus**; an
`{agent,tokens,ts}` write turns it into a live **per-agent monitor**. One substrate —
remember · message · monitor.

## Enable
```nix
services.sharedMemory = {
  enable = true;
  bindIp = "<this host's tailscale IP>";
  openFirewall = true;   # tailnet interface only
};
```
**NB:** `nixos-rebuild switch` is a human step — it rebuilds this host.
