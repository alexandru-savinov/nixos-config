// Bind probe for sancta-gallery's own-origin (tailnet) shape.
//
// A tailnet address is assigned by tailscaled, not owned by the host, so at boot
// the server can call bind() before the address exists and die with
// EADDRNOTAVAIL. This probe performs the EXACT same operation the server will,
// so the precondition it waits on and the one that actually fails are identical.
//
// EXIT CODES — three outcomes, never two:
//   0  proceed: the address is usable, or the bind failed for a reason the
//      server itself should report (EADDRINUSE — the address IS local and
//      something holds the port; EACCES/EPERM — the sandbox refused it)
//   1  wait: EADDRNOTAVAIL, and ONLY that. The address is not here yet.
//   2  the probe itself is broken (uncaught throw, bad require, …)
//
// 2 is not decoration. Node's default exit code for an uncaught exception is 1
// — the same as "wait" — so a broken probe would silently extend the wait to the
// full timeout and then report a missing tailnet address that was never missing.
// The wait loop treats anything that is not 0 or 1 as immediately fatal.
// Caught in review on #554.
const FAIL_INTERNAL = 2;

process.on("uncaughtException", (e) => {
  console.error("sancta-gallery-bind-probe: internal failure:", e && e.stack ? e.stack : e);
  process.exit(FAIL_INTERNAL);
});

const net = require("net");

const bind = process.env.GALLERY_BIND;
if (!bind) {
  // A configuration error, not a wait condition — let ExecStart fail visibly.
  console.error("sancta-gallery-bind-probe: GALLERY_BIND is unset");
  process.exit(0);
}

const s = net.createServer();
s.once("error", (e) => process.exit(e.code === "EADDRNOTAVAIL" ? 1 : 0));
s.listen(8739, bind, () => s.close(() => process.exit(0)));
