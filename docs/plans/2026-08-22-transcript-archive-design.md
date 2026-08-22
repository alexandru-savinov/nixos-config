# Transcript archive — design (2026-08-22)

Scopul, în vorbele lui: **(a) supraviețuire + (b) arhivă vie** pentru transcriptele
verbatim ale conversației (`/var/lib/sancta/.claude/projects/`, 530 MB azi,
~0,4–0,5 GB/lună, în accelerare). Azi singura copie trăiește pe volumul LUKS al
lui sancta-choir; tar-ul săptămânal al oglinzii le exclude deliberat.

Decizia lui (brainstorm 2026-08-22): abordarea A — **arhivă append-only de
obiecte criptate**, destinația **rpi5 prin transportul existent** (pull), formatul
pregătit ca un al treilea picior extern să fie doar „împinge aceleași obiecte
încă undeva" (aia, dacă vine, e grant nou → consiliu).

## Formă

- **Obiect = o sesiune închisă.** Un `*.jsonl` (sesiuni + subagenți) e „închis"
  când mtime-ul lui e mai vechi de 48 h. Sesiunile închise sunt imutabile în
  practică; dacă una totuși reînvie după arhivare, se arhivează DIN NOU ca
  versiune nouă — manifestul e append-only, nu suprascrie niciodată.
- **Criptare la producere:** `age` către ACEIAȘI doi destinatari ca oglinda
  (cheia de backup + cheia lui de recuperare; chei publice, declarate în nix).
  Pe rpi5 ajunge numai cifrotext — zero-knowledge, ca la oglindă.
- **Cheia timpului întâi** (doctrina object-store): 
  `soul-archive/AAAA/LL/<proiect>--<sesiune>.jsonl.age`
- **Manifest** `soul-archive/MANIFEST.jsonl`, append-only, un rând per obiect:
  `{ts, key, session, sha256_plain, sha256_cipher, bytes_plain, bytes_cipher, mtime_sursă}`.
  Scriere atomică (tmp + rename, același filesystem).

## Componente

1. **Modulul `sancta-transcript-archive`** (nixos-config, modelat pe
   sancta-statusline-refresh + lecțiile zilei):
   - unit oneshot + timer zilnic (`Persistent=true` — bătăile pierdute se recuperează);
   - User=sancta; ExecStartPre `test -x`; PATH-ul enumerat din CE APELEAZĂ scriptul
     (contractul ExecStart↔PATH, cu manifestul de contract extins);
   - ReadWritePaths: doar directorul arhivei; sursa (projects/) doar citire;
   - `flock -n` pe un lockfile (bătaie de timer vs rulare de mână, fără suprapunere);
   - aserțiune la build: destinatari age reali (ca la oglindă) — un placeholder
     PICĂ build-ul, nu tace la runtime.
   - Scriptul propriu-zis: `index/bin/transcript-archive` (pe suflet, git-uit) —
     scan → filtrare închise → diff față de manifest → criptează → manifest.
     Idempotent: un obiect deja în manifest cu același sha nu se re-criptează.
2. **Transportul — nimic nou:** directorul arhivei intră în ce publică deja
   choir spre pull-ul lui rpi5 (rrsync-ul e ancorat pe un singur director:
   fie arhiva se mută SUB `localDir`-ul publicat, fie endpoint-ul primește al
   doilea director — de ales în implementare pe ce permite rrsync-ul existent;
   preferată prima, zero schimbări pe rpi5).
3. **Garda `archive-check`** — handler nou în `bin/wq-tick` + rând în
   `producers.json`/absent-guard: orice sesiune închisă de >72 h care lipsește
   din manifest = alarmă; manifest neatins de >8 zile = alarmă (dead-man,
   aliniat cu pragul oglinzii). **Braț negativ obligatoriu:** testul corupe o
   copie de manifest și dovedește că garda PICĂ.
4. **Vederea derivată** (pentru latura „arhivă vie"): `soul-archive/INDEX.md`
   regenerat la fiecare rulare din manifest — pe luni, cu număr de sesiuni,
   bytes, intervale; niciodată editat de mână; trăiește lângă arhivă și în
   git-ul indexului nu intră (e derivat + mare).

## Precondiții verificate / de verificat

- ✔ Producătorul oglinzii pe choir: viu (tar-uri săptămânale, ultimul 2026-08-16).
- ✔ Spațiu pe rpi5: NVMe 119 G, 54 G liberi (~9 ani la ritmul actual) — sondat 2026-08-22.
- **⏳ Pull-ul pe rpi5:** de dovedit că `/var/lib/soul-mirror` conține tar-uri
  PROASPETE (sondă la mâna lui / agentul de Mac). Dacă e gol: cheia pull e
  neprovizionată și pull-ul se auto-suprimă tăcut — repararea devine Task 0,
  altfel arhiva ar „pleca" spre un seif care nu trage.
- **⏳ Alerta de staleness a pull-ului** trimite telegramul prin configul
  openclaw (`/var/lib/openclaw/...`) — infrastructură RETRASĂ; de re-legat la
  un canal viu sau de declarat că rămâne doar pe journal+stamp.

## Erori & margini

- Sursă în scriere în timpul scanării: exclusă prin regula 48 h (fișierele vii
  nu se ating). 
- Crash la jumătate: tmp+rename per obiect; manifestul se scrie DUPĂ obiect;
  un obiect fără rând de manifest e re-luat la următoarea bătaie (idempotent).
- Recipient greșit: build-assert; imposibil de ajuns silențios la runtime.
- Creștere: liniară cu arhiva (fiecare obiect o dată); prune NU există prin
  design — arhiva e memoria, nu un cache.

## Teste (spec de verificare, nu opțiune)

- fixture: sesiune falsă închisă → obiect .age + rând manifest + INDEX regenerat;
- braț negativ: manifest corupt → archive-check PICĂ; obiect lipsă → PICĂ;
- idempotență: a doua rulare = zero obiecte noi;
- module-eval: wiring unit (paths, PATH-contract, timer Persistent, flock);
- dry-build toate hosturile.

## Ce NU face (garduri de scop)

- NU șterge, NU mută, NU rescrie transcriptele-sursă. Niciodată.
- NU exportă nimic în afara tailnet-ului; niciun terț în v1.
- NU introduce chei noi și niciun secret prin chat (doar cheile PUBLICE age în nix).
- NU atinge mecanica pull-ului de pe rpi5 în v1 dincolo de publicarea directorului
  (excepție: dacă sonda dovedește pull-ul mort, repararea CHEII e task separat,
  la mâna lui — provisioning-ul e definit deja în modulul oglinzii).
