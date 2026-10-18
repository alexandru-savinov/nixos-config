// Kindle stub + reader for the isolated «kindle» VLAN. Node-side only: the
// browser JS lives in page.tpl.html and must stay ES5 (Kindle WebKit 534).
//
// Environment (set by the NixOS module; overridable for off-port tests):
//   PORT           listen port
//   STATE_DIR      where the server copy of the reading position lives
//   READER_DIR     generated reader (start.html, chapters.json, book/*.html)
//   WIFISTUB       file with the UUID body the Kindle Wi-Fi check expects
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
const START = fs.readFileSync(path.join(READER_DIR, "start.html"), "utf8");
const CHAPTERS = new Set(JSON.parse(fs.readFileSync(path.join(READER_DIR, "chapters.json"), "utf8")));
// Every page is loaded once; /r/<id> can only ever serve one of these.
const PAGES = new Map();
for (const id of [...CHAPTERS, "index"]) {
  PAGES.set(id, fs.readFileSync(path.join(READER_DIR, "book", id + ".html"), "utf8"));
}
const POS_FILE = path.join(STATE_DIR, "position.json");

const CH_RE = /^[12]-[0-9]{1,2}$/;
const F_RE = /^(0(\.[0-9]{1,4})?|1(\.0{1,4})?)$/; // 0..1, at most 4 decimals
const N_RE = /^[0-9]{1,15}$/; // cache-buster from the page; ignored

function validPos(ch, f) {
  return typeof ch === "string" && CH_RE.test(ch) && CHAPTERS.has(ch) &&
    typeof f === "number" && Number.isFinite(f) && f >= 0 && f <= 1 && F_RE.test(String(f));
}

// The saved position, or null. Re-validated on read: the file is trusted no more than a request.
function loadPos() {
  try {
    const p = JSON.parse(fs.readFileSync(POS_FILE, "utf8"));
    return p && validPos(p.ch, p.f) ? { ch: p.ch, f: p.f } : null;
  } catch (e) {
    return null;
  }
}

function savePos(ch, f) {
  const tmp = POS_FILE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify({ ch: ch, f: f }) + "\n");
  fs.renameSync(tmp, POS_FILE); // atomic on the same filesystem
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
  const f = Number(fs_);
  return validPos(ch, f) ? { ch: ch, f: f } : null;
}

// Values are validated, so JSON.stringify cannot break out of the script.
function withPos(html) {
  return html.replace("/*SRVPOS*/null", JSON.stringify(loadPos()));
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
    send(r, 200, withPos(START));
  } else if ((m = /^\/r\/(index|[12]-[0-9]{1,2})$/.exec(p)) && PAGES.has(m[1])) {
    send(r, 200, withPos(PAGES.get(m[1])));
  } else if (p === "/pos") {
    const pos = qi < 0 ? null : parsePos(url.slice(qi + 1));
    if (!pos) {
      r.writeHead(400, { "Cache-Control": "no-store" });
      r.end();
    } else {
      try {
        savePos(pos.ch, pos.f);
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
