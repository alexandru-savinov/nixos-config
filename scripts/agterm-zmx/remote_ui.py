#!/usr/bin/env python3
"""Ask a native question in the Mac pane attached to this remote session."""
import argparse
import json
import os
import socket
import sys

import host


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("title", nargs="?")
    parser.add_argument("--button", action="append", default=[], metavar="ID=LABEL")
    parser.add_argument("--hud", choices=["open", "update", "close"])
    parser.add_argument("--detail")
    args = parser.parse_args()
    buttons = []
    for value in args.button:
        identifier, separator, label = value.partition("=")
        if not separator:
            parser.error("buttons must be ID=LABEL")
        buttons.append({"id": identifier, "label": label})
    if args.hud:
        if buttons or (args.hud == "close" and (args.title or args.detail)):
            parser.error("HUD commands do not accept buttons; close takes no text")
        request = {"ui": "hud." + args.hud}
        if args.hud != "close":
            if not args.title:
                parser.error("HUD open/update requires message text")
            request["message"] = args.title
            if args.detail:
                request["detail"] = args.detail
    else:
        if not args.title or not buttons or args.detail:
            parser.error("a question requires a title and buttons")
        request = {"ui": "ask", "title": args.title, "buttons": buttons}
    qualified = os.environ.get("ZMX_SESSION", "")
    if not qualified.startswith("agt-mvp-"):
        parser.error("run inside an agterm remote zmx session")
    name = qualified.removeprefix("agt-mvp-")
    route = json.loads((host.state_dir() / (host.session_name(name) + ".route")).read_text())
    port = route.get("port")
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError("invalid attachment route")
    payload = (json.dumps(host.envelope(route, request)) + "\n").encode()
    if len(payload) > 6144:
        raise ValueError("question too large")
    with socket.create_connection(("127.0.0.1", port), timeout=3) as channel:
        channel.settimeout(310)
        channel.sendall(payload)
        with channel.makefile("rb") as stream:
            raw = stream.readline(4097)
        if len(raw) > 4096 or not raw.endswith(b"\n"):
            raise ValueError("attachment closed without an answer")
        result = json.loads(raw)
    print(json.dumps(result))
    return 0 if result.get("result") in {"answered", "ok"} else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError):
        print(json.dumps({"result": "error", "reason": "no usable Mac attachment"}))
        sys.exit(1)
