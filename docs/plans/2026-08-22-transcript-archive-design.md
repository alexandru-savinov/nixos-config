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
  Pe rpi5 ajunge numai cifrotext — zero-knowledge, ca la oglindă. Ca invariantul
  să fie REAL (revmux-574, MAJOR): în directorul publicat nu intră NICIO
  metadată în clar — nici manifest, nici INDEX, nici nume de fișiere purtătoare
  de proiect/sesiune (detaliile mai jos).
- **Cheia timpului întâi** (doctrina object-store), nume OPAC:
  `soul-archive/AAAA/LL/<sha256_plain-16>.jsonl.age`. Identitatea (proiect,
  sesiune, cale relativă) trăiește NUMAI în manifest, nu în numele obiectului.
  Numele pe conținut rezolvă și coliziunile (revmux-574, MAJOR): vechea formă
  `<proiect>--<sesiune>` nu reprezenta subcăile (68 de `journal.jsonl` sub
  `subagents/workflows/wf_*/` împart același basename) și o sesiune reînviată
  ar fi suprascris obiectul vechi sub aceeași cheie, cu manifestul arătând
  spre bytes dispăruți. Acum: conținut nou → hash nou → obiect NOU lângă cel
  vechi; nimic nu se suprascrie vreodată, iar re-arhivarea aceluiași conținut
  e no-op prin construcție.
- **Manifest** — canonic, ÎN CLAR, DOAR pe choir, în afara directorului
  publicat (`/var/lib/sancta/transcript-archive/MANIFEST.jsonl`), append-only,
  un rând per obiect:
  `{ts, key, relpath, session, sha256_plain, sha256_cipher, bytes_plain, bytes_cipher, src_mtime}`
  (`relpath` = calea sursă relativă la `projects/` — obligatorie acum, că
  numele obiectului nu o mai poartă; `src_mtime`, ASCII, în AMBELE documente —
  vechiul `mtime_sursă` de aici diverga de `src_mtime` din plan). Scriere
  atomică (tmp + rename, același filesystem). În directorul publicat merge un
  SNAPSHOT criptat `soul-archive/MANIFEST.jsonl.age`, rescris integral la
  fiecare rulare cu schimbări — restore-ul de pe rpi5 îl decriptează întâi.
- **Puls la FIECARE rulare** (revmux-574, MAJOR — dead-man-ul măsura ce nu
  trebuie): `last-run.json` (`{ts, scanned, archived}`) scris și la rulările
  fără nimic de arhivat, lângă manifestul canonic. Mtime-ul manifestului NU e
  semnal de viață — o săptămână sănătoasă fără sesiuni închise nu-l atinge.

## Componente

1. **Modulul `sancta-transcript-archive`** (nixos-config, modelat pe
   sancta-statusline-refresh + lecțiile zilei):
   - unit oneshot + timer zilnic (`Persistent=true` — bătăile pierdute se recuperează);
   - User=sancta; ExecStartPre `test -x`; PATH-ul enumerat din CE APELEAZĂ scriptul
     (contractul ExecStart↔PATH, cu manifestul de contract extins);
   - ReadWritePaths: doar directorul arhivei; sursa (projects/) doar citire;
   - `flock -n` pe un lockfile (bătaie de timer vs rulare de mână, fără suprapunere);
   - destinatarii: REFOLOSEȘTE `config.services.sancta-soul-mirror.recipients`
     (o singură sursă, zero derivă între module) + aserțiune la build că lista
     are ≥ 2 intrări — testul de prefix al oglinzii, singur, trece și pe listă
     goală sau cu un singur destinatar (revmux-574, MINOR);
   - poarta de montare (revmux-574, MAJOR): `after`/`requires` pe
     `sancta-soul-mount.service` + `ConditionPathIsMountPoint`, ca la TOATE
     unitățile care citesc sufletul (soul-mirror, statusline-refresh, worker) —
     altfel un volum nedeblocat după reboot înseamnă scan pe underlay-ul gol,
     exit 0, „sănătos"; iar garda, citind același gol, ar confirma minciuna.
   - Scriptul propriu-zis: `index/bin/transcript-archive` (pe suflet, git-uit) —
     scan → filtrare închise → diff față de manifest → criptează → manifest.
     Idempotent: un obiect deja în manifest cu același sha nu se re-criptează.
2. **Transportul — nimic nou:** SUB `localDir`-ul publicat intră NUMAI
   cifrotext (obiectele cu nume opace + `MANIFEST.jsonl.age`); manifestul în
   clar, `last-run.json` și `INDEX.md` rămân pe choir, în afara directorului
   publicat. rrsync-ul e ancorat pe un singur director: fie arhiva se mută SUB
   `localDir`, fie endpoint-ul primește al doilea director — de ales în
   implementare pe ce permite rrsync-ul existent; preferată prima, zero
   schimbări pe rpi5 (al cărui `remoteDir = "/"` trage TOT ce e publicat —
   încă un motiv ca acolo să nu existe nimic în clar).
3. **Garda `archive-check`** — handler nou în `bin/wq-tick` + rând în
   `producers.json`/absent-guard: orice sesiune închisă de >72 h care lipsește
   din manifest = alarmă; `last-run.json` mai vechi de 2 zile = alarmă
   (timer-ul e ZILNIC — pragul de 8 zile, împrumutat de la oglinda
   săptămânală, ar fi tolerat 8 bătăi ratate; revmux-574, MAJOR); obiect numit
   în manifest dar absent pe disc = alarmă; sursă nemontată/goală = alarmă,
   niciodată „sănătos". **Braț negativ obligatoriu:** testul corupe o copie de
   manifest și dovedește că garda PICĂ — adică handler-ul întoarce `{ok:false}`
   și rândul de coadă primește `last_error`; NU exit code de proces: bucla
   wq-tick prinde eșecul prin `Q.fail` și continuă să dreneze coada, singurul
   `process.exit` fiind halt-ul de orchestrator (revmux-574, MINOR — vechiul
   criteriu „exit nonzero" testa un semnal care nu există).
4. **Vederea derivată** (pentru latura „arhivă vie"): `INDEX.md` regenerat la
   fiecare rulare din manifest — pe luni, cu număr de sesiuni, bytes,
   intervale; niciodată editat de mână; trăiește lângă manifestul canonic pe
   choir (NU în directorul publicat — e metadată în clar) și în git-ul
   indexului nu intră (e derivat + mare).

## Precondiții verificate / de verificat

- ✔ Producătorul oglinzii pe choir: viu (tar-uri săptămânale, ultimul 2026-08-16).
- ✔ Spațiu pe rpi5: NVMe 119 G, 54 G liberi (~9 ani la ritmul actual) — sondat 2026-08-22.
- **⏳ Pull-ul pe rpi5:** de dovedit că `/var/lib/soul-mirror` conține tar-uri
  PROASPETE (sondă la mâna lui / agentul de Mac). Dacă e gol: cheia pull e
  neprovizionată și pull-ul se auto-suprimă tăcut — repararea devine Task 0,
  altfel arhiva ar „pleca" spre un seif care nu trage.
- **⏳ Alerta de staleness a pull-ului** trimite telegramul prin configul
  openclaw (`/var/lib/openclaw/...`) — infrastructură RETRASĂ; de re-legat la
  un canal viu sau de declarat că rămâne doar pe journal+stamp. MAI ASCUȚIT
  (revmux-574, neverificabil de pe choir): unitatea are `ReadOnlyPaths` pe
  acel path FĂRĂ prefixul `-` — dacă fișierul lipsește pe rpi5, systemd pică
  unitatea LA START, deci dead-man-ul receptorului pentru TOATĂ oglinda poate
  fi mort de tot, nu doar fără telegram. Sondă la mâna lui, pe rpi5:
  `test -e /var/lib/openclaw/.openclaw/openclaw.json; systemctl status soul-mirror-staleness`.

## Erori & margini

- Sursă în scriere în timpul scanării: exclusă prin regula 48 h (fișierele vii
  nu se ating). 
- Crash la jumătate: tmp+rename per obiect; manifestul se scrie DUPĂ obiect;
  un obiect fără rând de manifest e re-luat la următoarea bătaie (idempotent).
- Recipient greșit / listă scurtă: lista REFOLOSITĂ a oglinzii + aserțiunea
  de lungime ≥ 2 la build; imposibil de ajuns silențios la runtime.
- Creștere: liniară cu arhiva (fiecare obiect o dată); prune NU există prin
  design — arhiva e memoria, nu un cache.

## Teste (spec de verificare, nu opțiune)

- fixture: sesiune falsă închisă → obiect .age cu nume-hash + rând manifest
  (cu `relpath` + `src_mtime`) + INDEX regenerat + `last-run.json` atins;
- coliziune: două surse cu același basename (à la `journal.jsonl`) → două
  obiecte distincte; sursă „reînviată" cu conținut nou → al doilea obiect,
  primul NEATINS;
- braț negativ: manifest corupt → archive-check întoarce `{ok:false}`
  (`last_error` pe rândul de coadă); obiect lipsă → la fel; sursă
  goală/nemontată → la fel;
- rulare fără sesiuni închise → zero obiecte noi, dar `last-run.json` PROASPĂT;
- idempotență: a doua rulare = zero obiecte noi;
- module-eval: wiring unit (paths, PATH-contract, timer Persistent, flock,
  poarta de montare, recipients din oglindă + lungime ≥ 2);
- dry-build toate hosturile.

## Ce NU face (garduri de scop)

- NU șterge, NU mută, NU rescrie transcriptele-sursă. Niciodată.
- NICIUN terț în v1; ambele capete sunt hosturile noastre. Transportul e calea
  de pull EXISTENTĂ a oglinzii: rpi5 → SSH către IP-ul PUBLIC al lui choir
  (`soul-mirror-pull.nix` `remoteHost` — deliberat NU un nume de tailnet:
  Tailscale SSH pe choir autentifică după identitatea de tailnet, sare peste
  `authorized_keys` și ar ocoli comanda forțată `rrsync -ro`). Granița de
  securitate e criptarea age la repaus + comanda forțată legată de cheie în
  tranzit, NU tailnet-ul; a muta pe nume de tailnet ar SLĂBI-o. (Corectează
  P1-ul de pe #574 — formularea veche „nimic în afara tailnet-ului" era
  nesatisfiabilă pe acest transport.)
- NU introduce chei noi și niciun secret prin chat (doar cheile PUBLICE age în nix).
- NU atinge mecanica pull-ului de pe rpi5 în v1 dincolo de publicarea directorului
  (excepție: dacă sonda dovedește pull-ul mort, repararea CHEII e task separat,
  la mâna lui — provisioning-ul e definit deja în modulul oglinzii).
