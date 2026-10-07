// Builds the Kindle reader for «Пятнадцатилетний капитан» (Petrov, 1934, PD-old, ru.wikisource).
// usage: node build.js <wikitext> <page.tpl.html> <outdir>
const fs = require("fs"), path = require("path");
const [wikiPath, tplPath, out] = process.argv.slice(2);
const tpl = fs.readFileSync(tplPath, "utf8");
const lines = fs.readFileSync(wikiPath, "utf8").split("\n");

const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const inline = s => esc(s).replace(/''(.+?)''/g, "<i>$1</i>");
const sentence = s => s.charAt(0) + s.slice(1).toLowerCase();           // "ГЛАВА ВОСЬМАЯ" -> "Глава восьмая"
const fixTitle = s => s.replace(/Свнда/g, "Сэнда");                     // typo in the source heading

const chapters = [];
let part = 0, partName = "", cur = null, started = false;
for (const raw of lines) {
  const l = raw.trim();
  const h = l.match(/^=+\s*(.+?)\s*=+$/);
  if (h) {
    const t = h[1];
    if (/^ЧАСТЬ /.test(t)) { part++; partName = sentence(t); started = true; continue; }
    const g = t.match(/^(ГЛАВА [А-ЯЁ ]+?)\.\s*(.*)$/);
    if (g && started) {
      cur = { part, partName, n: 0, title: sentence(g[1]) + ". " + fixTitle(g[2]), paras: [] };
      cur.n = chapters.filter(c => c.part === part).length + 1;
      cur.id = part + "-" + cur.n;
      chapters.push(cur);
    }
    continue;
  }
  if (!cur || !l || /^\[\[Категория:/.test(l) || /^__/.test(l)) continue;
  const right = l.match(/^\{\{right\|(.*)\}\}$/);
  if (right) { cur.paras.push('<p class="r">' + inline(right[1]) + "</p>"); continue; }
  if (/\{\{|<[a-z]/i.test(l)) console.warn("unhandled markup in", cur.id, ":", l.slice(0, 60));
  cur.paras.push("<p>" + inline(l) + "</p>");
}

const fill = (o) => tpl
  .replace("%%DOCTITLE%%", o.doctitle).replace("%%ID%%", o.id)
  .replace("%%PREV%%", o.prev).replace("%%NEXT%%", o.next)
  .replace("%%ISCH%%", o.isCh ? "true" : "false").replace("%%BODY%%", o.body);

fs.mkdirSync(path.join(out, "book"), { recursive: true });
chapters.forEach((c, i) => {
  const body = "<h3>" + c.partName + "</h3>\n<h2>" + c.title + "</h2>\n" + c.paras.join("\n");
  fs.writeFileSync(path.join(out, "book", c.id + ".html"), fill({
    doctitle: "Капитан · " + c.id.replace("-", "."), id: c.id, isCh: true, body,
    prev: i > 0 ? chapters[i - 1].id : "", next: i < chapters.length - 1 ? chapters[i + 1].id : "",
  }));
});

// contents
let toc = "<h2>Пятнадцатилетний капитан</h2>\n<h3>Жюль Верн · перевод И. Петрова, 1934</h3>\n<ul>\n";
let lastPart = 0;
for (const c of chapters) {
  if (c.part !== lastPart) { toc += '<li class="part">' + c.partName + "</li>\n"; lastPart = c.part; }
  toc += '<li id="c-' + c.id + '"><a href="/r/' + c.id + '">' + c.n + ". " + esc(c.title.replace(/^Глава [а-яё ]+\.\s*/, "")) + "</a></li>\n";
}
toc += "</ul>";
fs.writeFileSync(path.join(out, "book", "index.html"),
  fill({ doctitle: "Капитан · содержание", id: "index", isCh: false, body: toc, prev: "", next: "" }));

// "/" -> resume: this browser's position first, else the server's copy (embedded at serve time), else Part 2 Chapter 8
fs.writeFileSync(path.join(out, "start.html"),
  '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Капитан</title>' +
  "<style>body{background:#000;color:#fff;font:24px Georgia,serif;margin:40px}a{color:#fff}</style></head>" +
  '<body><p><a href="/r/2-8">Пятнадцатилетний капитан — читать</a></p>' +
  '<script>(function(){var S=/*SRVPOS*/null,c=null;try{c=localStorage.getItem("k_ch")}catch(e){}' +
  'if(c&&/^[12]-[0-9]{1,2}$/.test(c))location.replace("/r/"+c);' +
  'else if(S&&S.ch)location.replace("/r/"+S.ch+"#f="+S.f);' +
  'else location.replace("/r/2-8");})();</script></body></html>');

// the server accepts /pos only for these ids
fs.writeFileSync(path.join(out, "chapters.json"), JSON.stringify(chapters.map(c => c.id)) + "\n");

if (chapters.length !== 38) throw new Error("expected 38 chapters, got " + chapters.length);

const total = chapters.reduce((a, c) => a + c.paras.length, 0);
console.log("chapters:", chapters.length, "(part1:", chapters.filter(c => c.part === 1).length,
  "part2:", chapters.filter(c => c.part === 2).length + ")", " paragraphs:", total);
const c28 = chapters.find(c => c.id === "2-8");
console.log("2-8:", c28.title, "| first:", c28.paras[0].slice(3, 60));
console.log("sizes KB: min", Math.min(...chapters.map(c => c.paras.join("").length)) / 1000 | 0,
  "max", Math.max(...chapters.map(c => c.paras.join("").length)) / 1000 | 0);
