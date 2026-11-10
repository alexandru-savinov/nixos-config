# The Kindle reader built from pinned ru.wikisource texts and pictures.json.
# Separate from the module so the flake checks can build it on any system:
# build.js fails on a picture anchor that does not resolve, and CI only
# evaluates rpi5-full, so this is where a bad anchor is caught before merge.
{ pkgs }:

let
  # https://ru.wikisource.org/wiki/Пятнадцатилетний_капитан_(Верн;_Петров), revision 5648532 (2025-09-10).
  bookText = pkgs.fetchurl {
    name = "pyatnadcatiletniy-kapitan-5648532.wiki";
    url = "https://ru.wikisource.org/w/index.php?title=%D0%9F%D1%8F%D1%82%D0%BD%D0%B0%D0%B4%D1%86%D0%B0%D1%82%D0%B8%D0%BB%D0%B5%D1%82%D0%BD%D0%B8%D0%B9_%D0%BA%D0%B0%D0%BF%D0%B8%D1%82%D0%B0%D0%BD_(%D0%92%D0%B5%D1%80%D0%BD;_%D0%9F%D0%B5%D1%82%D1%80%D0%BE%D0%B2)&oldid=5648532&action=raw";
    hash = "sha256-d0AwVZ8mMntCwc332ExSPII1VWOSJh6SQWmeRXIaUlw=";
  };

  # https://ru.wikisource.org/wiki/Капитанская_дочка_(Пушкин)/1978_(СО), revision 5754617 (2026-10-03).
  dochkaText = pkgs.fetchurl {
    name = "kapitanskaya-dochka-5754617.wiki";
    url = "https://ru.wikisource.org/w/index.php?title=%D0%9A%D0%B0%D0%BF%D0%B8%D1%82%D0%B0%D0%BD%D1%81%D0%BA%D0%B0%D1%8F_%D0%B4%D0%BE%D1%87%D0%BA%D0%B0_(%D0%9F%D1%83%D1%88%D0%BA%D0%B8%D0%BD)/1978_(%D0%A1%D0%9E)&oldid=5754617&action=raw";
    hash = "sha256-H+sKr73LfI/4RCEc6sJvDl/E85tfLJut9KYksEJhy/Q=";
  };
in
pkgs.runCommand "kindle-reader" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
  node ${./build.js} ${./page.tpl.html} $out ${bookText} ${dochkaText} ${./pictures.json}
''
