{ lib }:
let
  matches = pattern: value: builtins.isString value && builtins.match pattern value != null;
  # Nix counts UTF-8 bytes; the runtime's string bounds count UTF-16 units.
  utf16Length = value:
    let
      firstNonAscii = builtins.fromJSON ''"\u0080"'';
      continuation = builtins.substring 1 1 firstNonAscii;
      twoByteLead = builtins.substring 0 1 firstNonAscii;
      fourByteLead = builtins.substring 0 1 "😀";
    in
    lib.foldl'
      (length: byte: length + (
        if byte < continuation then 1
        else if byte >= fourByteLead then 2
        else if byte >= twoByteLead then 1 else 0
      )) 0
      (lib.stringToCharacters value);
  text = value: builtins.isString value && builtins.stringLength value > 0
    && utf16Length value <= 2048 && builtins.match ".*[[:cntrl:]].*" value == null;
  keys = value: allowed: required: builtins.isAttrs value
    && lib.all (key: builtins.elem key allowed) (builtins.attrNames value)
    && lib.all (key: builtins.hasAttr key value) required;
  integer = value: low: high: builtins.isInt value && value >= low && value <= high;
  absolute = value: text value && lib.hasPrefix "/" value;
  decimal = value:
    let
      normalized =
        if builtins.stringLength value > 1 && lib.hasPrefix "0" value
        then decimal (lib.removePrefix "0" value) else lib.toInt value;
    in
    normalized;
  duration = value:
    let
      parts = if builtins.isString value then builtins.match "([1-9][0-9]*)([smhd])" value else null;
      number = if parts == null then "" else builtins.head parts;
      multiplier = { s = 1000; m = 60000; h = 3600000; d = 86400000; };
    in
    parts != null && builtins.stringLength number <= 16
    && decimal number <= builtins.div 9007199254740991 multiplier.${builtins.elemAt parts 1};
  name = value: matches "[a-z0-9][a-z0-9-]{0,63}" value && value != "vigil" && !(lib.hasPrefix "invalid-" value);
  tailnet = value:
    let parts = lib.splitString "." value;
    in builtins.length parts == 4 && lib.all (part: matches "(0|[1-9][0-9]{0,2})" part) parts
      && lib.all (part: lib.toInt part <= 255) parts
      && builtins.head parts == "100" && lib.toInt (builtins.elemAt parts 1) >= 64 && lib.toInt (builtins.elemAt parts 1) <= 127;
  # Mask strings before checking syntax. '#' and punctuation inside quotes are
  # data; scanning raw source with a syntax regex would reject valid contracts.
  mask = line:
    let
      length = builtins.stringLength line;
      char = index: builtins.substring index 1 line;
      quoted = index:
        if index >= length then throw "unterminated string"
        else if char index == "\"" then index + 1
        else if char index == "\\" then
          if index + 1 >= length then throw "invalid escape"
          else if builtins.elem (char (index + 1)) [ "\"" "\\" ] then quoted (index + 2)
          else if char (index + 1) == "u" && matches "[0-9a-fA-F]{4}" (builtins.substring (index + 2) 4 line)
          then quoted (index + 6) else throw "invalid escape"
        else quoted (index + 1);
      scan = index:
        if index >= length || char index == "#" then ""
        else if char index == "\"" then "\"s\"" + scan (quoted (index + 1))
        else char index + scan (index + 1);
    in
    scan 0;
  space = "[ \t]*";
  key = "[a-zA-Z0-9_-]+";
  scalar = ''("s"|true|false|[+-]?(0|[1-9][0-9]*))'';
  array = ''[[]${space}("s"(${space},${space}"s")*${space},?)?${space}[]]'';
  pair = "${key}${space}=${space}${scalar}";
  inline = "[{]${space}(${pair}(${space},${space}${pair})*)?${space}[}]";
  syntax = source: builtins.stringLength source <= 65536 && lib.all
    (line:
      let masked = mask (lib.removeSuffix "\r" line);
      in matches "${space}" masked || matches "${space}[[]${key}[]]${space}" masked
        || matches "${space}${key}${space}=${space}(${scalar}|${array}|${inline})${space}" masked
    )
    (lib.splitString "\n" source);
  validate = document:
    let
      c = document.contract or { };
      expectation = c.astept or { };
      kind = c.verifica or "";
      target = c.tinta or null;
      tcp = if builtins.isString target then builtins.match "([[][0-9a-fA-F:]+[]]|[^:[:space:]/]+):([0-9]+)" target else null;
      url = if builtins.isString target then builtins.match "[Hh][Tt][Tt][Pp][Ss]?://([^/?#[:space:]@]+)([/#?].*)?" (lib.strings.trim target) else null;
      authority =
        if kind == "tcp" && tcp != null then builtins.head tcp
        else if kind == "http" && url != null then builtins.head url else "";
      httpAuthority = builtins.match "([[][0-9a-fA-F:]+[]]|[^:]+)(:([0-9]*))?" authority;
      httpPort = if httpAuthority == null then null else builtins.elemAt httpAuthority 2;
      validHttpPort = httpAuthority != null && (httpPort == null || httpPort == ""
        || decimal httpPort <= 65535);
      host =
        if lib.hasPrefix "[" authority then lib.removePrefix "[" (builtins.head (lib.splitString "]" authority))
        else builtins.head (lib.splitString ":" authority);
      peer = !(tailnet host || lib.hasPrefix "fd7a:115c:a1e0:" (lib.toLower host)) || (c.peer or false);
    in
    keys document [ "contract" "spune" ] [ "contract" "spune" ]
    && keys c [ "nume" "ce" "verifica" "tinta" "astept" "prag" "picat_dupa" "peer" "dimension" "driver" ] [ "nume" "ce" "verifica" "tinta" "picat_dupa" ]
    && keys document.spune [ "nivel" ] [ "nivel" ]
    && name c.nume && text c.ce && utf16Length c.ce <= 200
    && builtins.elem kind [ "tcp" "http" "unit" "age" "disk" "mount" "cmd" "hass-state" ]
    && integer c.picat_dupa 1 12 && (!(c ? peer) || builtins.isBool c.peer)
    # Borrowed vocabulary: closed label sets, mirrored from lib/schema.mjs.
    && (!(c ? dimension) || builtins.elem c.dimension [ "accuracy" "completeness" "conformity" "consistency" "coverage" "timeliness" "uniqueness" "availability" ])
    && (!(c ? driver) || builtins.elem c.driver [ "regulatory" "analytics" "operational" "family" ])
    && builtins.elem document.spune.nivel [ "nota" "incident" ] && peer
    && (if kind == "cmd" then builtins.isList target && builtins.length target > 0
    && builtins.length target <= 32 && lib.all text target && absolute (builtins.head target) else text target)
    # Full WHATWG URL and ECMAScript regex validation is mandatory in the
    # public-contract build derivation, using the exact runtime validator.
    && (if kind == "http" then (url == null || validHttpPort)
    && keys expectation [ "status" "body" "prospetime" ] [ "status" ] && integer expectation.status 100 599
    && (!(expectation ? body) || text expectation.body)
    && (!(expectation ? prospetime) || duration expectation.prospetime)
    else if kind == "cmd" then keys expectation [ "valoare" ] [ "valoare" ] && text expectation.valoare
    # hass-state: exactly one of `valoare` (state equality) or `disponibil = true`
    # (state is not unavailable/unknown). Mirrors lib/schema.mjs; the fixtures
    # in pkgs/vigil/schema-fixtures.json hold both sides to the same answers.
    else if kind == "hass-state" then keys expectation [ "valoare" "disponibil" ] [ ]
    && ((expectation ? valoare) != (expectation ? disponibil))
    && (!(expectation ? valoare) || text expectation.valoare)
    && (!(expectation ? disponibil) || expectation.disponibil == true)
    else !(c ? astept))
    && (if kind == "age" then (absolute target || matches "unit:[a-zA-Z0-9@_.:-]+\\.service" target) && duration (c.prag or null)
    else if kind == "disk" then absolute target && integer (c.prag or null) 1 100 else !(c ? prag))
    && (kind != "tcp" || tcp != null && integer (decimal (builtins.elemAt tcp 1)) 1 65535)
    && (kind != "unit" || matches "[a-zA-Z0-9@_.:-]+\\.service" target)
    && (kind != "mount" || absolute target)
    && (kind != "hass-state" || (matches "[a-z_][a-z0-9_]*\\.[a-z0-9_]+" target
    && !(matches "(person|device_tracker|mobile_app)\\..*" target)));
  parseSource = file: source:
    let
      checked = builtins.tryEval (
        let parsed = if syntax source then builtins.fromTOML source else throw "unsupported syntax";
        in if validate parsed then parsed else throw "invalid contract"
      );
      value = checked.value;
    in
    if checked.success then value.contract // { nivel = value.spune.nivel; }
    else throw "vigil: invalid contract ${toString file}";
  parse = file: parseSource file (builtins.readFile file);
in
{ inherit parse parseSource tailnet syntax validate; }
