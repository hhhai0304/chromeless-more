#!/usr/bin/env python3
"""chromelessctl — drive a running Chromeless over its control socket.

The app listens on ~/Library/Application Support/Chromeless/control.sock
once View ▸ Remote Control is on (or it was launched with --remote). The
wire is one JSON object per line; this tool is the friendly front end, and
importing it gives the same commands as functions for other tooling.

Commands only reach AI tabs — the ones this tool opens itself, marked
orange in the tab bar with an "AI" pill. The user's own tabs answer with
an error, and nothing here ever takes the user's foreground.

    chromelessctl.py windows
    chromelessctl.py profiles                  # profile list + the AI's bound one
    chromelessctl.py open example.com          # new AI tab, background
    chromelessctl.py open example.com --profile work
    chromelessctl.py eval 'document.title' --tab 1
    chromelessctl.py click 'button.buy' --tab 1
    chromelessctl.py type '#q' 'search terms' --clear --tab 1
    chromelessctl.py press Enter --tab 1
    chromelessctl.py wait 'document.querySelector(".done")' --tab 1
    chromelessctl.py snap /tmp/page.png --tab 1
    chromelessctl.py text | html | logs --tab 1
    chromelessctl.py back | forward | reload | stop | activate | close --tab 1
"""

import argparse
import json
import os
import socket
import sys
import time

SOCK = os.environ.get(
    "CHROMELESS_SOCK",
    os.path.expanduser("~/Library/Application Support/Chromeless/control.sock"))

MAX_REPLY = 64 * 1024 * 1024


class ControlError(Exception):
    pass


def request(payload, sock_path=SOCK, timeout=30):
    """Send one JSON command, return the JSON reply. Raises ControlError."""
    if not os.path.exists(sock_path):
        raise ControlError(
            "no control socket at %s — is Chromeless running with remote "
            "control on? (View ▸ Remote Control, or launch with --remote)"
            % sock_path)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout)
        s.connect(sock_path)
        s.sendall(json.dumps(payload).encode() + b"\n")
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1024 * 1024)
            if not chunk:
                break
            buf += chunk
            if len(buf) > MAX_REPLY:
                raise ControlError("reply exceeded %d bytes" % MAX_REPLY)
    except socket.timeout:
        raise ControlError("timed out waiting for the app — it may be showing "
                           "a dialog only a person can answer")
    except ConnectionRefusedError:
        raise ControlError("control socket refused the connection — "
                           "restart Chromeless")
    finally:
        s.close()
    if not buf:
        raise ControlError("the app closed the socket without replying")
    return json.loads(buf)


def call(cmd, sock_path=SOCK, **params):
    """Send a command and unwrap the reply, raising on ok:false."""
    payload = {"cmd": cmd}
    payload.update({k: v for k, v in params.items() if v is not None})
    resp = request(payload, sock_path)
    if not resp.get("ok"):
        raise ControlError(resp.get("error", "command failed"))
    return resp


def _target(args):
    return {"window": getattr(args, "window", None),
            "tab": getattr(args, "tab", None)}


# --- in-page actions -------------------------------------------------------
# click/type/press are JavaScript dispatched as real events, which is what
# the app itself would produce for a script injected into the page. They are
# untrusted events — the one thing pages can tell apart from a finger — and
# in practice that only matters to sites actively hunting for automation.

def click(selector, sock=SOCK, **target):
    js = """
    (function () {
      var el = document.querySelector(%s);
      if (!el) return {ok: false, error: "no element matches selector"};
      el.scrollIntoView({block: "center", inline: "center"});
      var r = el.getBoundingClientRect();
      var opts = {bubbles: true, cancelable: true, view: window,
                  clientX: r.left + r.width / 2, clientY: r.top + r.height / 2,
                  button: 0};
      el.dispatchEvent(new MouseEvent("mouseover", opts));
      el.dispatchEvent(new MouseEvent("mousedown", opts));
      el.focus();
      el.dispatchEvent(new MouseEvent("mouseup", opts));
      el.dispatchEvent(new MouseEvent("click", opts));
      return {ok: true, tag: el.tagName.toLowerCase(),
              text: (el.innerText || el.value || "").trim().slice(0, 80)};
    })()
    """ % json.dumps(selector)
    return call("eval", sock, js=js, **target)


def type_text(selector, text, clear=False, sock=SOCK, **target):
    js = """
    (function () {
      var el = document.querySelector(%s);
      if (!el) return {ok: false, error: "no element matches selector"};
      el.scrollIntoView({block: "center"});
      el.focus();
      if (%s && "value" in el) el.value = "";
      var text = %s;
      if (el.isContentEditable) {
        el.textContent += text;
        el.dispatchEvent(new InputEvent("input", {bubbles: true, inputType: "insertText"}));
      } else {
        var proto = el instanceof HTMLTextAreaElement
          ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto, "value").set;
        for (var ch of text) {
          setter.call(el, el.value + ch);
          el.dispatchEvent(new InputEvent("input", {bubbles: true,
            inputType: "insertText", data: ch}));
        }
      }
      el.dispatchEvent(new Event("change", {bubbles: true}));
      return {ok: true, value: el.value !== undefined ? el.value : el.textContent};
    })()
    """ % (json.dumps(selector), json.dumps(clear), json.dumps(text))
    return call("eval", sock, js=js, **target)


KEYS = {
    "Enter": ("Enter", "Enter", 13), "Tab": ("Tab", "Tab", 9),
    "Escape": ("Escape", "Escape", 27), "Backspace": ("Backspace", "Backspace", 8),
    "Delete": ("Delete", "Delete", 46), "Space": (" ", "Space", 32),
    "ArrowUp": ("ArrowUp", "ArrowUp", 38), "ArrowDown": ("ArrowDown", "ArrowDown", 40),
    "ArrowLeft": ("ArrowLeft", "ArrowLeft", 37), "ArrowRight": ("ArrowRight", "ArrowRight", 39),
    "Home": ("Home", "Home", 36), "End": ("End", "End", 35),
    "PageUp": ("PageUp", "PageUp", 33), "PageDown": ("PageDown", "PageDown", 34),
}


def press(key, sock=SOCK, **target):
    kc = KEYS.get(key, (key, key, ord(key.upper()[0]) if len(key) == 1 else 0))
    js = """
    (function () {
      var el = document.activeElement && document.activeElement !== document.body
        ? document.activeElement : document.body;
      var opts = {bubbles: true, cancelable: true, key: %s, code: %s,
                  keyCode: %d, which: %d};
      el.dispatchEvent(new KeyboardEvent("keydown", opts));
      el.dispatchEvent(new KeyboardEvent("keypress", opts));
      el.dispatchEvent(new KeyboardEvent("keyup", opts));
      return {ok: true, key: %s, on: el.tagName.toLowerCase()};
    })()
    """ % (json.dumps(kc[0]), json.dumps(kc[1]), kc[2], kc[2], json.dumps(kc[0]))
    return call("eval", sock, js=js, **target)


def wait_for(js_expr, timeout=10.0, sock=SOCK, **target):
    deadline = time.monotonic() + timeout
    while True:
        resp = call("eval", sock, js="Boolean(%s)" % js_expr, **target)
        if resp.get("value"):
            return {"ok": True, "waited": round(timeout - (deadline - time.monotonic()), 2)}
        if time.monotonic() >= deadline:
            raise ControlError("wait timed out after %gs: %s" % (timeout, js_expr))
        time.sleep(0.25)


def page_text(sock=SOCK, **target):
    return call("eval", sock, js="document.body ? document.body.innerText : ''", **target)


def page_html(sock=SOCK, **target):
    return call("eval", sock, js="document.documentElement.outerHTML", **target)


# --- CLI -------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(prog="chromelessctl", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--socket", default=SOCK, help="control socket path")
    target = argparse.ArgumentParser(add_help=False)
    target.add_argument("--window", type=int, default=None,
                        help="window index (default: key window)")
    target.add_argument("--tab", type=int, default=None,
                        help="tab index (default: active tab)")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("ping")
    sub.add_parser("windows")
    sub.add_parser("profiles", help="list profiles and the AI's bound one")
    o = sub.add_parser("open", parents=[target],
                       help="open a URL in a new AI tab (always background)")
    o.add_argument("url")
    o.add_argument("--profile", default=None,
                   help="profile id or name the AI session should use")
    n = sub.add_parser("nav", parents=[target], help="navigate an existing AI tab")
    n.add_argument("url")
    e = sub.add_parser("eval", parents=[target], help="evaluate JavaScript in a tab")
    e.add_argument("js")
    e.add_argument("--raw", action="store_true", help="print string results unquoted")
    s = sub.add_parser("snap", parents=[target], help="save a PNG of a tab")
    s.add_argument("path")
    c = sub.add_parser("click", parents=[target],
                       help="click the first element matching a CSS selector")
    c.add_argument("selector")
    t = sub.add_parser("type", parents=[target],
                     help="type into an input/textarea/contenteditable")
    t.add_argument("selector")
    t.add_argument("text")
    t.add_argument("--clear", action="store_true", help="clear the field first")
    k = sub.add_parser("press", parents=[target],
                       help="press a key (Enter, Tab, Escape, arrows, or a character)")
    k.add_argument("key")
    w = sub.add_parser("wait", parents=[target],
                       help="poll a JS expression until it is truthy")
    w.add_argument("expr")
    w.add_argument("--timeout", type=float, default=10.0)
    sub.add_parser("text", parents=[target], help="the page's visible text")
    sub.add_parser("html", parents=[target], help="the page's full DOM")
    lg = sub.add_parser("logs", parents=[target],
                        help="the AI tab's console, page errors and fetch/XHR calls")
    lg.add_argument("--kind", choices=["console", "error", "net"],
                    help="only entries of this kind")
    lg.add_argument("--limit", type=int, default=100, help="tail N entries (max 400)")
    lg.add_argument("--clear", action="store_true", help="drain the log after reading")
    for cmd in ("back", "forward", "reload", "stop", "activate", "close"):
        sub.add_parser(cmd, parents=[target])

    args = p.parse_args(argv)
    tgt = _target(args)

    try:
        cmd = args.command
        if cmd == "ping":
            out = request({"cmd": "ping"}, args.socket)
        elif cmd == "windows":
            out = call("windows", args.socket)
        elif cmd == "profiles":
            out = call("profiles", args.socket)
        elif cmd == "open":
            # request() rather than call(): a needProfile reply is not an
            # error to unwrap but the profile list to hand back.
            payload = {"cmd": "open", "url": args.url,
                       "profile": args.profile, **tgt}
            out = request({k: v for k, v in payload.items() if v is not None},
                          args.socket)
            print(json.dumps(out, indent=2, ensure_ascii=False))
            sys.exit(0 if out.get("ok") else 1)
        elif cmd == "nav":
            out = call("navigate", args.socket, url=args.url, **tgt)
        elif cmd == "eval":
            out = call("eval", args.socket, js=args.js, **tgt)
            if args.raw and isinstance(out.get("value"), str):
                print(out["value"])
                return
        elif cmd == "snap":
            out = call("snap", args.socket, path=os.path.abspath(args.path), **tgt)
        elif cmd == "click":
            out = click(args.selector, sock=args.socket, **tgt)
            out = out.get("value", out)
        elif cmd == "type":
            out = type_text(args.selector, args.text, clear=args.clear, sock=args.socket, **tgt)
            out = out.get("value", out)
        elif cmd == "press":
            out = press(args.key, sock=args.socket, **tgt)
            out = out.get("value", out)
        elif cmd == "wait":
            out = wait_for(args.expr, args.timeout, sock=args.socket, **tgt)
        elif cmd == "text":
            print(page_text(sock=args.socket, **tgt).get("value", ""))
            return
        elif cmd == "html":
            print(page_html(sock=args.socket, **tgt).get("value", ""))
            return
        elif cmd == "logs":
            out = call("logs", args.socket, kind=args.kind, limit=args.limit,
                       clear=args.clear or None, **tgt)
        else:
            out = call(cmd, args.socket, **tgt)
        print(json.dumps(out, indent=2, ensure_ascii=False))
    except ControlError as exc:
        print("chromelessctl: %s" % exc, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
