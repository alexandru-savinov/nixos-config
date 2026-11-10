// Kindle stub + reader for the isolated «kindle» VLAN. Node-side only: the
// browser JS lives in page.tpl.html and must stay ES5 (Kindle WebKit 534).
//
// Environment (set by the NixOS module; overridable for off-port tests):
//   PORT           listen port
//   STATE_DIR      where the server copy of the reading position lives
//   READER_DIR     generated shelf (shelf.html, b-<slug>.html, books.json, book/*.html)
//   WIFISTUB       file with the UUID body the Kindle Wi-Fi check expects
//   IMG_DIR        directory with the pictures books.json lists (read per request)
//   SUBNET_PREFIX  e.g. "192.168.30." for the /check page
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = parseInt(process.env.PORT || "80", 10);
const STATE_DIR = process.env.STATE_DIR;
const READER_DIR = process.env.READER_DIR;
const PREFIX = process.env.SUBNET_PREFIX || "192.168.30.";
if (!STATE_DIR || !READER_DIR || !process.env.WIFISTUB) {
  console.error("STATE_DIR, READER_DIR and WIFISTUB must be set");
  process.exit(1);
}

const UUID = fs.readFileSync(process.env.WIFISTUB);
const SHELF = fs.readFileSync(path.join(READER_DIR, "shelf.html"), "utf8");
// Each book: its chapter ids, its contents page, and the file its position is saved in.
// Every page is loaded once; /r/<id> and /b/<slug> can only ever serve one of these.
const BOOKS = new Map(), BOOK_OF = new Map(), PAGES = new Map(), IMGS = new Set();
const IMG_DIR = process.env.IMG_DIR || "";
for (const bk of JSON.parse(fs.readFileSync(path.join(READER_DIR, "books.json"), "utf8"))) {
  if (!/^[a-z]{1,16}$/.test(bk.slug) || !/^[a-z0-9.-]{1,32}\.json$/.test(bk.posFile)) throw new Error("bad book " + bk.slug);
  const b = { slug: bk.slug, ids: new Set(bk.ids), posFile: path.join(STATE_DIR, bk.posFile),
    start: fs.readFileSync(path.join(READER_DIR, "b-" + bk.slug + ".html"), "utf8") };
  BOOKS.set(bk.slug, b);
  for (const f of bk.imgs || []) {
    if (!/^[a-z0-9-]{1,32}\.jpg$/.test(f)) throw new Error("bad image " + f);
    IMGS.add(f);
  }
  for (const id of [...bk.ids, bk.toc]) {
    if (BOOK_OF.has(id)) throw new Error("duplicate id " + id);
    BOOK_OF.set(id, b);
    PAGES.set(id, fs.readFileSync(path.join(READER_DIR, "book", id + ".html"), "utf8"));
  }
}

const CH_RE = /^([12]|d)-[0-9]{1,2}$/;
const F_RE = /^(0(\.[0-9]{1,4})?|1(\.0{1,4})?)$/; // 0..1, at most 4 decimals
const N_RE = /^[0-9]{1,15}$/; // cache-buster from the page; ignored

function validPos(b, ch, f) {
  return typeof ch === "string" && CH_RE.test(ch) && b.ids.has(ch) &&
    typeof f === "number" && Number.isFinite(f) && f >= 0 && f <= 1 && F_RE.test(String(f));
}

// A book's saved position, or null. Re-validated on read: the file is trusted no more than a request.
function loadPos(b) {
  try {
    const p = JSON.parse(fs.readFileSync(b.posFile, "utf8"));
    return p && validPos(b, p.ch, p.f) ? { ch: p.ch, f: p.f } : null;
  } catch (e) {
    return null;
  }
}

function savePos(b, ch, f) {
  const tmp = b.posFile + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify({ ch: ch, f: f }) + "\n");
  fs.renameSync(tmp, b.posFile); // atomic on the same filesystem
}

// Parse /pos?ch=..&f=..[&n=..] strictly: exactly these keys, each once.
function parsePos(query) {
  const q = new URLSearchParams(query);
  const keys = [...q.keys()];
  if (keys.some(function (k) { return k !== "ch" && k !== "f" && k !== "n"; })) return null;
  if (q.getAll("ch").length !== 1 || q.getAll("f").length !== 1 || q.getAll("n").length > 1) return null;
  const ch = q.get("ch"), fs_ = q.get("f"), n = q.get("n");
  if (n !== null && !N_RE.test(n)) return null;
  if (!F_RE.test(fs_)) return null;
  const f = Number(fs_), b = BOOK_OF.get(ch);
  return b && validPos(b, ch, f) ? { b: b, ch: ch, f: f } : null;
}

// Values are validated, so JSON.stringify cannot break out of the script.
function withPos(html, b) {
  return html.replace("/*SRVPOS*/null", JSON.stringify(loadPos(b)));
}
function shelf() {
  let html = SHELF;
  for (const b of BOOKS.values()) html = html.replace("/*SRVPOS:" + b.slug + "*/null", JSON.stringify(loadPos(b)));
  return html;
}

function send(r, code, body, type) {
  const b = Buffer.isBuffer(body) ? body : Buffer.from(body);
  r.writeHead(code, {
    "Content-Type": type || "text/html; charset=utf-8",
    "Content-Length": b.length,
    "Cache-Control": "no-cache",
  });
  r.end(b);
}

http.createServer(function (q, r) {
  const url = q.url || "";
  const qi = url.indexOf("?");
  const p = qi < 0 ? url : url.slice(0, qi);
  const ip = (q.socket.remoteAddress || "").replace("::ffff:", "");
  let m;
  if (q.method !== "GET") {
    r.writeHead(404);
    r.end();
  } else if (p === "/kindle-wifi/wifistub.html" || p === "/kindle-wifi/wifistub-eink.html") {
    send(r, 200, UUID, "text/html");
  } else if (p === "/") {
    send(r, 200, shelf());
  } else if ((m = /^\/b\/([a-z]{1,16})$/.exec(p)) && BOOKS.has(m[1])) {
    send(r, 200, withPos(BOOKS.get(m[1]).start, BOOKS.get(m[1])));
  } else if ((m = /^\/r\/(index|d-index|([12]|d)-[0-9]{1,2})$/.exec(p)) && PAGES.has(m[1])) {
    send(r, 200, withPos(PAGES.get(m[1]), BOOK_OF.get(m[1])));
  } else if ((m = /^\/img\/([a-z0-9-]{1,32}\.jpg)$/.exec(p)) && IMGS.has(m[1]) && IMG_DIR) {
    let img = null;
    try { img = fs.readFileSync(path.join(IMG_DIR, m[1])); } catch (e) { console.error("missing picture " + m[1]); }
    if (img) {
      r.writeHead(200, { "Content-Type": "image/jpeg", "Content-Length": img.length, "Cache-Control": "max-age=604800" });
      r.end(img);
    } else {
      r.writeHead(404);
      r.end();
    }
  } else if (p === "/pos") {
    const pos = qi < 0 ? null : parsePos(url.slice(qi + 1));
    if (!pos) {
      r.writeHead(400, { "Cache-Control": "no-store" });
      r.end();
    } else {
      try {
        savePos(pos.b, pos.ch, pos.f);
        r.writeHead(204, { "Cache-Control": "no-store" });
      } catch (e) {
        console.error("cannot save position: " + e.message);
        r.writeHead(500, { "Cache-Control": "no-store" });
      }
      r.end();
    }
  } else if (p === "/check") {
    const ok = ip.indexOf(PREFIX) === 0;
    send(r, 200,
      "<html><body><h1>" + (ok ? "OK" : "NOT ISOLATED") + "</h1>" +
      "<p>You are " + ip + "</p>" +
      "<p>" + (ok ? "On the kindle network, served by rpi5." : "This device is NOT on the kindle network.") + "</p>" +
      "<p>" + new Date().toISOString().slice(0, 19) + "Z</p></body></html>");
  } else {
    r.writeHead(404);
    r.end();
  }
  console.log(ip + " " + q.method + " " + url.slice(0, 200) + " " + r.statusCode);
// Not 127.0.0.1: the Kindle reaches this host over the LAN. The nixos-fw rule is the gate.
}).listen(PORT, "0.0.0.0", function () {
  console.log("kindle-stub listening on :" + PORT);
});
