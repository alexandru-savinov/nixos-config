# OpenClaw ZDR Proxy package
#
# Wraps `proxy.py` with a Python interpreter that has Flask, Requests, and
# Gunicorn available, then exposes `bin/openclaw-zdr-proxy` which launches
# the WSGI app under gunicorn bound to 127.0.0.1.
#
# Imported by `modules/services/openclaw-zdr-proxy.nix` to construct the
# `ExecStart=` for the systemd unit.

{ pkgs }:

let
  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      flask
      requests
      gunicorn
    ]
  );

  proxySource = pkgs.runCommand "openclaw-zdr-proxy-source" { } ''
    mkdir -p $out
    cp ${./proxy.py} $out/proxy.py
  '';
in
pkgs.writeShellApplication {
  name = "openclaw-zdr-proxy";
  runtimeInputs = [ pythonEnv ];
  text = ''
    set -euo pipefail
    : "''${OPENCLAW_ZDR_PROXY_PORT:=5780}"
    cd ${proxySource}
    exec gunicorn \
      --bind "127.0.0.1:''${OPENCLAW_ZDR_PROXY_PORT}" \
      --workers 2 \
      --access-logfile - \
      --error-logfile - \
      --log-level info \
      proxy:app
  '';
}
