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
  `soul-archive/AAAA/LL/<sha256_cipher-16>.jsonl.age` — hash-ul CIFROTEXTULUI,
  nu al plaintextului (codex P2 pe #576: un nume derivat din sha256_plain ar
  lăsa pe oricine are un CANDIDAT de conținut să-i confirme prezența și să
  coreleze plaintexturi egale, fără nicio cheie; hash-ul cifrotextului e
  calculabil din bytes publicați — deci garda poate verifica integritatea
  nume↔bytes fără chei — și nu spune nimic despre conținut, age fiind
  nedeterminist). Identitatea (proiect, sesiune, cale relativă) și
  sha256_plain trăiesc NUMAI în manifest. Numele pe conținut rezolvă și
  coliziunile (revmux-574, MAJOR): vechea formă `<proiect>--<sesiune>` nu
  reprezenta subcăile (68 de `journal.jsonl` sub `subagents/workflows/wf_*/`
  împart același basename) și o sesiune reînviată ar fi suprascris obiectul
  vechi sub aceeași cheie, cu manifestul arătând spre bytes dispăruți. Acum:
  conținut nou → obiect NOU lângă cel vechi; nimic nu se suprascrie vreodată.
  Idempotența se judecă după `sha256_plain` căutat ÎN MANIFEST (nu după
  existența numelui pe disc): conținut deja arhivat = no-op.
- **Manifest** — canonic, ÎN CLAR, DOAR pe choir, în afara directorului
  publicat (`/var/lib/sancta/transcript-archive/MANIFEST.jsonl`), append-only,
  un rând per obiect:
  `{ts, key, relpath, session, sha256_plain, sha256_cipher, bytes_plain, bytes_cipher, src_mtime}`
  (`relpath` = calea sursă relativă la `projects/` — obligatorie acum, că
  numele obiectului nu o mai poartă; `src_mtime`, ASCII, în AMBELE documente —
  vechiul `mtime_sursă` de aici diverga de `src_mtime` din plan). Scriere
  atomică (tmp + rename, același filesystem). În directorul publicat merge un
  SNAPSHOT criptat `soul-archive/MANIFEST.jsonl.age`; restore-ul de pe rpi5
  îl decriptează întâi. Împrospătarea NU se leagă de „au fost schimbări":
  fiecare rulare compară `sha256(MANIFEST.jsonl)` cu sursa înregistrată în
  `last-snapshot.json` și rescrie snapshotul la NEPOTRIVIRE (codex P2 pe
  #576: un crash între append-ul canonic și rescrierea snapshotului ar lăsa
  altfel un obiect publicat pe veci fără rândul care-l identifică — regula
  pe potrivire de hash se autovindecă la următoarea bătaie).
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
   - ReadWritePaths: DOAR cele două directoare ale arhivei — subdirectorul
     publicat (cifrotext) + directorul choir-only al manifestului; sursa
     (projects/) doar citire;
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
   în manifest dar absent pe disc = alarmă; obiect al cărui nume NU e
   sha256-ul propriilor bytes = alarmă (verificabil fără chei — vezi numele
   pe cifrotext); snapshot criptat cu sursa nepotrivită față de manifestul
   canonic = alarmă; sursă nemontată/goală = alarmă, niciodată „sănătos". **Braț negativ obligatoriu:** testul corupe o copie de
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

## Transport — verificat din repo (2026-08-23, Task 1)

Verificarea s-a făcut DIN REPO + din bytes-ii reali ai `rrsync`-ului din store,
fără să atingă niciun host. Trei întrebări: unde publică choir, cum ancorează
rpi5, ce permite de fapt rrsync-ul.

**1. Unde publică choir cifrotextul.**
`services.sancta-soul-mirror.localDir`, default `/var/lib/sancta/soul-mirror`
(`modules/services/sancta-soul-mirror.nix:248-252`), creat de tmpfiles ca
`d ${cfg.localDir} 0700 ${cfg.user} - -` (`:290-292`) — deci **700, owner
`sancta`**, exact userul sub care va rula și arhivatorul. Pe host e activat în
`hosts/sancta-choir/configuration.nix:236-242` cu `user = "sancta"` și un
`pullPubKey` REAL (nu placeholder) — endpoint-ul e viu, nu inert.

**2. Endpoint-ul — comanda forțată, citată** (`sancta-soul-mirror.nix:301-304`):

```nix
users.users.${cfg.user}.openssh.authorizedKeys.keys =
  mkIf (lib.hasPrefix "ssh-" cfg.pullPubKey) [
    ''restrict,command="${rrsync}/bin/rrsync -ro ${cfg.localDir}" ${cfg.pullPubKey}''
  ];
```

Receptorul: `hosts/rpi5-full/soul-mirror-pull.nix` — `remoteUser = "sancta"`,
`remoteHost = "116.203.223.113"` (IP PUBLIC, deliberat nu nume de tailnet:
`:157-164`), `remoteDir = "/"` interpretat RELATIV la rădăcina restricționată
(`:167-182`), tras cu `rsync -az -e "$SSH" "$REMOTE:$REMOTE_DIR" "$VAULT/"`
(`:92-95`).

**3. Constrângerea reală a rrsync-ului** (citită din
`/nix/store/…-rrsync-3.4.1/bin/rrsync`, nu din memorie):

- `arg_parser.add_argument('dir', metavar='DIR', …)` (`:376`) — **UN SINGUR**
  director restricționat, pozițional. Nu există „a doua rădăcină" într-o
  comandă forțată.
- `os.chdir(args.dir)` (`:203`); în `validated_arg` (`:295-307`) orice `..`
  omoară sesiunea, iar un argument absolut e RE-ANCORAT sub `args.dir`
  (`arg = args.dir + arg`). Confinarea e reală, nu convențională.
- `short_disabled_subdir = 'KLk'` (`:30`) — pe rădăcină ≠ `/` se dezactivează
  doar opțiunile de symlink (`--copy-links`/`--copy-dirlinks`/
  `--keep-dirlinks`). **Recursivitatea NU e dezactivată**: `-a` (⊃ `-r`) coboară
  liber în subdirectoare.

**4. Sondă locală — comportament, nu doar cod** (2026-08-23; niciun host atins:
un shell fals face exact ce face sshd sub comanda forțată — pune comanda
clientului în `SSH_ORIGINAL_COMMAND` și lansează literal
`rrsync -ro <dir-publicat>`; clientul e invocația EXACTĂ a lui rpi5,
`rsync -az -e … "$REMOTE:/" "$VAULT/"`):

| Ce s-a probat | Rezultat |
|---|---|
| A. Pull cu `remoteDir="/"` peste un `soul-archive/2026/08/*.jsonl.age` imbricat | **ajunge tot**: tar-ul săptămânal + cele două obiecte + `MANIFEST.jsonl.age`, zero config nou |
| B. Aceeași cheie cere un director FRATE (absolut) | respins — calea e re-ancorată sub rădăcină: `change_dir ".../published/tmp/.../secret-sibling" failed` |
| C. Traversare cu `..` | respins — `do not use .. in arg` |
| D. Scriere înapoi în endpoint | respins — `sending to read-only server is not allowed` |

Adică: subdirectorul e liber ȘI confinarea rămâne întreagă. Decizia de mai jos
nu se sprijină pe citit cod, ci pe B/C/D observate.

**Decizia: arhiva stă SUB directorul publicat** —
`/var/lib/sancta/soul-mirror/soul-archive/AAAA/LL/<sha256_cipher-16>.jsonl.age`.

De ce nu al doilea endpoint: comanda forțată e per-CHEIE și rrsync ia un singur
DIR, deci „al doilea director" înseamnă a doua pereche de chei → al doilea
secret agenix pe rpi5 → a doua unitate de pull pe rpi5. Adică exact mecanica de
pull pe care v1 a jurat să n-o atingă. Iar varianta „mut rădăcina rrsync pe un
părinte comun" (`/var/lib/sancta`) ar deschide cheii de pull volumul sufletului
însuși — lărgire de endpoint dincolo de directorul publicat, interzisă explicit.
Subdirectorul e singura opțiune care nu costă nimic: recursivitatea e deja
permisă, deci **zero schimbări pe rpi5**.

Consecințe confirmate din cod, nu presupuse:

- Obiectele ajung singure în `/var/lib/soul-mirror/soul-archive/AAAA/LL/` —
  `remoteDir = "/"` + `-a` le duce fără nicio linie nouă de config.
- **Nimic nu le taie**: AMBELE prune-uri (choir `sancta-soul-mirror.nix:131-132`,
  rpi5 `soul-mirror-pull.nix:100-101`) globuiesc strict
  `sancta-soul-*.tar.gz.age`. Arhiva nu e atinsă de niciunul — exact ce cere
  „prune NU există prin design".
- Dead-man-ul de staleness (`:119-146`) se uită la același glob de tar-uri
  săptămânale: nemodificat, nederanjat.
- Producătorul oglinzii tar-uiește din `soulRoot` = `/var/lib/sancta/.claude`,
  care NU conține `localDir` — arhiva nu se auto-împachetează în oglindă.
- Corolarul ascuțit: fiindcă rpi5 trage TOT ce e sub `localDir`, orice bucată de
  text-clar pusă acolo pleacă de pe host. De asta manifestul canonic,
  `last-run.json` și `INDEX.md` stau în `/var/lib/sancta/transcript-archive/`,
  în AFARA directorului publicat.

## Precondiții verificate / de verificat

- ✔ Producătorul oglinzii pe choir: viu (tar-uri săptămânale; ultimul
  2026-08-23, văzut în `/var/lib/sancta/soul-mirror/`).
- ✔ Spațiu pe rpi5: NVMe 119 G, 54 G liberi (~9 ani la ritmul actual) — sondat 2026-08-22.
- **✔ Spațiu pe CHOIR** (întrebarea deschisă a revmux, măsurată 2026-08-23):
  `/` are 75 G, 24 G liberi (67% folosit). Transcriptele (~0,5 GB/lună) și
  arhiva (~0,5 GB/lună) cresc pe ACELAȘI disc, fără prune prin design ⇒
  ~2 ani de aer la ritmul curent. Nu blochează v1; gardă de spațiu liber în
  `archive-check` = element de backlog cu termen.
- **✔ Pull-ul pe rpi5 — DOVEDIT 2026-08-22, sonda lui de pe Mac:** seiful
  `/var/lib/soul-mirror` e întreg și proaspăt (4/4 tar-uri, byte-identice cu
  producătorul de pe choir).
- **✔ Alerta de staleness a pull-ului — SONDATĂ pe rpi5, 2026-08-22, mâna
  lui.** Verdict: dead-man-ul receptorului e VIU (3 rulări consecutive OK,
  20–22 aug, `status=0`; zero `Failed with result` în jurnal). Premisa
  ascuțită a revmux (`ReadOnlyPaths` fără `-` pe un path absent ⇒ unitatea
  pică la start) NU se confirmă empiric — explicația lui, consistentă cu
  dovezile: sub `ProtectSystem=strict` întreg `/` e deja read-only, iar un
  `ReadOnlyPaths` redundant e eliminat ca no-op înainte de verificarea căii.
  Path-ul openclaw lipsește (userul nici nu există pe rpi5), deci telegramul
  NU pleacă — dar scriptul îl tratează opțional (`jq … || true`), așa că
  fallback-ul journal+stamp e REAL, nu sperat. Igienă separată: linia moartă
  `ReadOnlyPaths` se scoate din modul (recomandarea lui), PR dedicat.

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

- fixture: sesiune falsă închisă → obiect .age numit după sha256_cipher +
  rând manifest (cu `relpath` + `src_mtime`) + INDEX regenerat +
  `last-run.json` atins + snapshot criptat împrospătat;
- snapshot rămas în urmă (simulat: șters/înlocuit după append-ul canonic) →
  următoarea rulare îl regenerează din potrivirea de hash;
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
