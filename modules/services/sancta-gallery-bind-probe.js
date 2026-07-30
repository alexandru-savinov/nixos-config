// Bind probe for sancta-gallery's own-origin (tailnet) shape.
//
// A tailnet address is assigned by tailscaled, not owned by the host, so at boot
// the server can call bind() before the address exists and die with
// EADDRNOTAVAIL. This probe performs the EXACT same operation the server will,
// so the precondition it waits on and the one that actually fails are identical.
//
// Exit 1 means ONLY "the address is not here yet — keep waiting". Every other
// outcome exits 0 so the wait loop stops and ExecStart reports the real error
// instead of this probe masking it as a timeout:
//   EADDRINUSE — the address IS local; something else holds the port
//   EACCES/EPERM — the systemd sandbox refused the bind (SocketBindDeny)
//
// Port 8739 is deliberate and must not become 0/ephemeral: SocketBindDeny=any
// applies to ExecStartPre too, so an ephemeral port would fail with EACCES,
// this probe would exit 0 immediately, and the wait would guard nothing.
const net = require("net");

const bind = process.env.GALLERY_BIND;
if (!bind) {
  console.error("sancta-gallery-bind-probe: GALLERY_BIND is unset");
  process.exit(0); // not a "wait" condition — let ExecStart fail visibly
}

const s = net.createServer();
s.once("error", (e) => process.exit(e.code === "EADDRNOTAVAIL" ? 1 : 0));
s.listen(8739, bind, () => s.close(() => process.exit(0)));
