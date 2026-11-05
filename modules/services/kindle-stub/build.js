// Builds the Kindle shelf: two public-domain books from pinned ru.wikisource revisions.
//   «Пятнадцатилетний капитан» (Verne, tr. Petrov 1934, PD-old)
//   «Капитанская дочка» (Pushkin 1836, 1978 edition text, PD-old)
// usage: node build.js <page.tpl.html> <outdir> <kapitan.wiki> <dochka.wiki>
//
// Output: book/<id>.html per chapter and contents page, b-<slug>.html (resume) per book,
// shelf.html ("/"), and books.json, which tells the server which ids exist and where
// each book's position is saved.
const fs = require("fs"), path = require("path");
const [tplPath, out, kapitanPath, dochkaPath] = process.argv.slice(2);
const tpl = fs.readFileSync(tplPath, "utf8");

const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const inline = s => esc(s).replace(/''(.+?)''/g, "<i>$1</i>");
const sentence = s => s.charAt(0) + s.slice(1).toLowerCase();           // "ГЛАВА ВОСЬМАЯ" -> "Глава восьмая"

// «Пятнадцатилетний капитан»: "ЧАСТЬ" headings, then "ГЛАВА <word>. <title>"; ids 1-1..2-20.
function parseKapitan(text) {
  const fixTitle = s => s.replace(/Свнда/g, "Сэнда");                   // typo in the source heading
  const chapters = [];
  let part = 0, partName = "", cur = null, started = false;
  for (const raw of text.split("\n")) {
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
  for (const c of chapters) {
    c.head = "<h3>" + c.partName + "</h3>\n<h2>" + c.title + "</h2>";
    c.toc = c.n + ". " + c.title.replace(/^Глава [а-яё ]+\.\s*/, "");
    c.label = "ч. " + c.part + ", гл. " + c.n;
    c.doc = c.id.replace("-", ".");
  }
  if (chapters.length !== 38) throw new Error("kapitan: expected 38 chapters, got " + chapters.length);
  return chapters;
}

// «Капитанская дочка»: one "=== Глава <roman>. <title> ===" heading per chapter, then the
// "ПРИЛОЖЕНИЕ. ПРОПУЩЕННАЯ ГЛАВА" Pushkin left out of the final text; the editors'
// "ПРИМЕЧАНИЯ" after it are not part of the novel and are not built. Ids d-1..d-15.
function parseDochka(text) {
  const lines = text.split("\n");
  const chapters = [];
  let cur = null, pre = [], i = 0, unhandled = 0;
  // ref = a footnote in the text (a translation of a foreign word); shown inline in brackets.
  const body = s => inline(s.replace(/<ref>(.*?)<\/ref>/g, "\u0001$1\u0002"))
    .replace(/\u0001(.*?)\u0002/g, " <small>[$1]</small>")
    .replace(/&lt;sup&gt;(.*?)&lt;\/sup&gt;/g, "<sup>$1</sup>");
  const epigraph = (verse, who) => verse.split(/\n/).map(v => v.trim()).filter(Boolean)
    .map(v => '<p class="r">' + body(v) + "</p>").concat('<p class="r"><i>' + body(who) + "</i></p>");
  const push = h => (cur ? cur.paras : pre).push(h);
  while (i < lines.length && !/^\}\}\s*$/.test(lines[i])) i++;          // skip the {{Отексте ...}} header
  for (i++; i < lines.length; i++) {
    const l = lines[i].trim();
    const h = l.match(/^=+\s*(.+?)\s*=+$/);
    if (h) {
      const t = h[1];
      if (t === "ПРИМЕЧАНИЯ") break;
      if (t === "----") { push('<p class="c">* * *</p>'); continue; }
      const g = t.match(/^Глава ([IVXLC]+)\.\s*(.+)$/i);
      const app = t.match(/^ПРИЛОЖЕНИЕ\.\s*(ПРОПУЩЕННАЯ ГЛАВА)/);
      if (g || app) {
        cur = { paras: [] };
        cur.n = chapters.length + 1;
        cur.id = "d-" + cur.n;
        if (g) {
          cur.title = "Глава " + g[1].toUpperCase() + ". " + sentence(g[2]);
          cur.toc = g[1].toUpperCase() + ". " + sentence(g[2]);
          cur.label = "гл. " + g[1].toUpperCase();
          cur.doc = g[1].toUpperCase();
        } else {
          cur.title = "Приложение. " + sentence(app[1]) + "<sup>1</sup>";
          cur.toc = "Приложение. " + sentence(app[1]);
          cur.label = "приложение";
          cur.doc = "приложение";
        }
        cur.head = "<h2>" + cur.title + "</h2>";
        chapters.push(cur);
        continue;
      }
      throw new Error("dochka: unexpected heading: " + t);
    }
    if (!l || /^\[\[Категория:/.test(l) || /^__/.test(l)) continue;
    let m;
    if (/^\{\{Эпиграф3\|/.test(l)) {                                     // may span lines (<poem>)
      let s = l;
      while (!/\}\}$/.test(s) && i + 1 < lines.length) s += "\n" + lines[++i];
      m = s.match(/^\{\{Эпиграф3\|(?:<poem>)?([\s\S]*?)(?:<\/poem>)?\|([^|]*)\}\}$/);
      if (!m) throw new Error("dochka: cannot parse epigraph: " + s.slice(0, 60));
      epigraph(m[1], m[2]).forEach(push);
      continue;
    }
    if ((m = l.match(/^\{\{right\|(.*)\}\}$/))) { push('<p class="r">' + body(m[1]) + "</p>"); continue; }
    if ((m = l.match(/^<center>(.*)<\/center>$/))) { push('<p class="c">' + body(m[1]) + "</p>"); continue; }
    if ((m = l.match(/^<sup>1<\/sup>\s*(.*)$/))) { push('<p class="n"><sup>1</sup> <i>' + body(m[1]) + "</i></p>"); continue; }
    if (/\{\{|<(?!ref>|\/ref>)[a-z]/i.test(l)) { unhandled++; console.warn("unhandled markup in", cur && cur.id, ":", l.slice(0, 60)); }
    push("<p>" + body(l) + "</p>");
  }
  if (chapters.length !== 15) throw new Error("dochka: expected 14 chapters + appendix, got " + chapters.length);
  if (unhandled) throw new Error("dochka: " + unhandled + " lines with unhandled markup");
  // The book's own epigraph comes before chapter I.
  chapters[0].head = pre.join("\n") + "\n" + chapters[0].head;
  return chapters;
}

const books = [
  {
    slug: "kapitan", key: "k", toc: "index", def: "2-8", posFile: "position.json",
    chRe: "^[12]-[0-9]{1,2}$", short: "Капитан",
    title: "Пятнадцатилетний капитан", by: "Жюль Верн · перевод И. Петрова, 1934",
    chapters: parseKapitan(fs.readFileSync(kapitanPath, "utf8")),
  },
  {
    slug: "dochka", key: "kd", toc: "d-index", def: "d-1", posFile: "position-dochka.json",
    chRe: "^d-[0-9]{1,2}$", short: "Дочка",
    title: "Капитанская дочка", by: "Александр Пушкин · 1836",
    chapters: parseDochka(fs.readFileSync(dochkaPath, "utf8")),
  },
];

const fill = (o) => tpl
  .replace("%%DOCTITLE%%", o.doctitle).replace("%%ID%%", o.id).replace(/%%KEY%%/g, o.key)
  .replace("%%TOC%%", o.toc)
  .replace("%%PREV%%", o.prev).replace("%%NEXT%%", o.next)
  .replace("%%ISCH%%", o.isCh ? "true" : "false").replace("%%BODY%%", o.body);

fs.mkdirSync(path.join(out, "book"), { recursive: true });
for (const bk of books) {
  const chs = bk.chapters;
  chs.forEach((c, i) => {
    fs.writeFileSync(path.join(out, "book", c.id + ".html"), fill({
      doctitle: bk.short + " · " + c.doc, id: c.id, key: bk.key, toc: bk.toc, isCh: true,
      body: c.head + "\n" + c.paras.join("\n"),
      prev: i > 0 ? chs[i - 1].id : "", next: i < chs.length - 1 ? chs[i + 1].id : "",
    }));
  });

  // contents
  let toc = '<p><a href="/">&larr; Все книги</a></p>\n<h2>' + bk.title + "</h2>\n<h3>" + bk.by + "</h3>\n<ul>\n";
  let lastPart = 0;
  for (const c of chs) {
    if (c.part && c.part !== lastPart) { toc += '<li class="part">' + c.partName + "</li>\n"; lastPart = c.part; }
    toc += '<li id="c-' + c.id + '"><a href="/r/' + c.id + '">' + esc(c.toc) + "</a></li>\n";
  }
  toc += "</ul>";
  fs.writeFileSync(path.join(out, "book", bk.toc + ".html"),
    fill({ doctitle: bk.short + " · содержание", id: bk.toc, key: bk.key, toc: bk.toc, isCh: false, body: toc, prev: "", next: "" }));

  // /b/<slug> -> resume: this browser's position first, else the server's copy (embedded at serve time),
  // else the book's default chapter.
  fs.writeFileSync(path.join(out, "b-" + bk.slug + ".html"),
    '<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + bk.short + "</title>" +
    "<style>body{background:#000;color:#fff;font:24px Georgia,serif;margin:40px}a{color:#fff}</style></head>" +
    '<body><p><a href="/r/' + bk.def + '">' + bk.title + " — читать</a></p>" +
    '<script>(function(){var S=/*SRVPOS*/null,c=null;try{c=localStorage.getItem("' + bk.key + '_ch")}catch(e){}' +
    "if(c&&/" + bk.chRe + '/.test(c))location.replace("/r/"+c);' +
    'else if(S&&S.ch)location.replace("/r/"+S.ch+"#f="+S.f);' +
    'else location.replace("/r/' + bk.def + '");})();</script></body></html>');
}

// "/" -> the shelf. Each book shows where it was left off: this browser first, else the server copy.
const labels = {};
for (const bk of books) for (const c of bk.chapters) labels[c.id] = c.label;
let shelf = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Книги</title>' +
  "<style>body{background:#000;color:#fff;font:26px Georgia,serif;margin:40px}" +
  "body.day{background:#fff;color:#000}a{color:inherit}h1{font-size:1.1em;margin:0 0 1em 0}" +
  "div.b{border:2px solid;padding:16px 20px;margin:0 0 28px 0}div.b a{text-decoration:none;display:block}" +
  "div.b span{display:block;font-size:0.75em;margin-top:6px}div.b i{display:block;font-size:0.75em;margin-top:8px}</style></head>" +
  "<body><h1>Книги</h1>\n";
for (const bk of books) {
  shelf += '<div class="b"><a href="/b/' + bk.slug + '">' + bk.title + "<span>" + bk.by + "</span>" +
    '<i id="at-' + bk.slug + '"></i></a></div>\n';
}
shelf += "<script>(function(){var L=" + JSON.stringify(labels) + ",B=[";
shelf += books.map(bk => '["' + bk.slug + '","' + bk.key + '",/*SRVPOS:' + bk.slug + "*/null]").join(",");
shelf += "];function ls(k){try{return localStorage.getItem(k)}catch(e){return null}}" +
  'if(ls("k_night")==="0")document.body.className="day";' +
  "for(var i=0;i<B.length;i++){var c=ls(B[i][1]+\"_ch\"),f=parseFloat(ls(B[i][1]+\"_frac\")||\"\"),S=B[i][2];" +
  "if(!(c&&L[c])&&S&&L[S.ch]){c=S.ch;f=S.f}" +
  "if(c&&L[c])document.getElementById(\"at-\"+B[i][0]).innerHTML=\"&#9656; читаете: \"+L[c]+(f>=0&&f<=1?\", \"+Math.round(f*100)+\"%\":\"\")}" +
  "})();</script></body></html>";
fs.writeFileSync(path.join(out, "shelf.html"), shelf);

// the server accepts /r/<id> and /pos only for these ids
fs.writeFileSync(path.join(out, "books.json"), JSON.stringify(books.map(bk => ({
  slug: bk.slug, toc: bk.toc, posFile: bk.posFile, ids: bk.chapters.map(c => c.id),
}))) + "\n");

for (const bk of books) {
  const chs = bk.chapters, total = chs.reduce((a, c) => a + c.paras.length, 0);
  console.log(bk.slug + ": chapters", chs.length, "paragraphs", total,
    "| sizes KB min", Math.min(...chs.map(c => c.paras.join("").length)) / 1000 | 0,
    "max", Math.max(...chs.map(c => c.paras.join("").length)) / 1000 | 0);
}
