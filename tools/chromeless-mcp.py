#!/usr/bin/env python3
"""chromeless-mcp — expose Chromeless remote control as MCP tools.

A zero-dependency MCP stdio server: newline-delimited JSON-RPC in, same out.
Point an MCP-aware agent at it and it can drive the browser — open pages,
click, type, read the DOM, and look at the page through screenshots — while
Chromeless keeps its own cookies, profiles, and logged-in sessions.

    { "mcpServers": { "chromeless": {
        "command": "python3",
        "args": ["/path/to/chromeless-more/tools/chromeless-mcp.py"] } } }

The app must be running with remote control on: View ▸ Remote Control, or
launch with --remote.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chromelessctl as ctl  # noqa: E402

PROTOCOL_VERSION = "2024-11-05"

TARGET = {
    "window": {"type": "integer",
               "description": "window index from chromeless_windows (default: key window)"},
    "tab": {"type": "integer",
            "description": "tab index within that window (default: active tab)"},
}


def _props(*names, required=(), extra=None):
    props = dict(TARGET)
    props.update(extra or {})
    schema = {"type": "object", "properties": props}
    if required:
        schema["required"] = list(required)
    return schema


_RULES = (" Only AI tabs — tabs this session opened, marked orange — accept "
          "commands; the user's own tabs refuse them, and nothing takes the "
          "user's foreground.")

TOOLS = [
    ("chromeless_ping", "Check the Chromeless control socket is live.", _props()),
    ("chromeless_windows",
     "List every window and tab with its index, title, URL, active/loading state, "
     "and whether it is an AI tab you may command. Use the indexes to target "
     "other tools.", _props()),
    ("chromeless_profiles",
     "List the browser's profiles and which one this AI session is bound to. "
     "When chromeless_open answers needProfile, ask the user which profile "
     "the AI may use and retry with that profile.", _props()),
    ("chromeless_open",
     "Open a URL in a NEW AI tab — always in the background, never taking the "
     "user's foreground. Bare domains and search phrases work like the app's "
     "own address bar. 'window' picks which window hosts the tab. With more "
     "than one profile the first call answers needProfile plus the profile "
     "list: ask the user which profile the AI may use, then retry passing it "
     "as 'profile' — the pick binds the session until remote control restarts.",
     _props(required=["url"], extra={
         "url": {"type": "string"},
         "profile": {"type": "string",
                     "description": "profile id or name the AI session should use"}})),
    ("chromeless_navigate", "Navigate an AI tab to a URL." + _RULES,
     _props(required=["url"], extra={"url": {"type": "string"}})),
    ("chromeless_evaluate",
     "Run JavaScript in an AI tab's page and return its JSON-safe result. "
     "Returned promises are awaited. The escape hatch: anything not covered "
     "by a dedicated tool." + _RULES,
     _props(required=["js"], extra={
         "js": {"type": "string", "description": "a JS expression or IIFE"}})),
    ("chromeless_screenshot",
     "Capture an AI tab as a PNG image — what the page actually looks like." + _RULES,
     _props()),
    ("chromeless_click",
     "Click the first element matching a CSS selector, with a real "
     "mouseover→mousedown→focus→mouseup→click event sequence." + _RULES,
     _props(required=["selector"], extra={"selector": {"type": "string"}})),
    ("chromeless_type",
     "Type text into an input, textarea, or contenteditable, character by "
     "character with input events (React-safe)." + _RULES,
     _props(required=["selector", "text"], extra={
         "selector": {"type": "string"},
         "text": {"type": "string"},
         "clear": {"type": "boolean", "description": "clear the field first"}})),
    ("chromeless_press",
     "Press a key on the focused element: Enter, Tab, Escape, Backspace, "
     "Delete, Space, arrows, Home, End, PageUp, PageDown, or a single character."
     + _RULES,
     _props(required=["key"], extra={"key": {"type": "string"}})),
    ("chromeless_wait_for",
     "Poll a JS expression in an AI tab until it is truthy — e.g. wait for an "
     "element to appear after a click or a load." + _RULES,
     _props(required=["js"], extra={
         "js": {"type": "string"},
         "timeout": {"type": "number", "description": "seconds (default 10)"}})),
    ("chromeless_page_text",
     "The AI tab's visible text (innerText) — the fastest way to read a page." + _RULES,
     _props()),
    ("chromeless_logs",
     "The AI tab's debugging feed: console messages, page errors, and "
     "fetch/XHR network calls with status and timing." + _RULES,
     _props(extra={
         "kind": {"type": "string", "enum": ["console", "error", "net"]},
         "limit": {"type": "integer", "description": "tail N entries (default 100, max 400)"},
         "clear": {"type": "boolean", "description": "drain the log after reading"}})),
    ("chromeless_back", "Go back in the AI tab's history." + _RULES, _props()),
    ("chromeless_forward", "Go forward in the AI tab's history." + _RULES, _props()),
    ("chromeless_reload", "Reload the AI tab." + _RULES, _props()),
    ("chromeless_activate",
     "Select one of the AI tabs in a window — allowed only while the front "
     "tab is already an AI tab, so it never takes the user's foreground."
     + _RULES, _props()),
    ("chromeless_close",
     "Close an AI tab. Windows are never closed remotely. A live session may "
     "ask the user to confirm first." + _RULES, _props()),
]

_TOOL_MAP = {name: (desc, schema) for name, desc, schema in TOOLS}


def _text(s):
    return {"content": [{"type": "text", "text": s}]}


def _err(s):
    return {"content": [{"type": "text", "text": s}], "isError": True}


def _target(args):
    return {"window": args.get("window"), "tab": args.get("tab")}


def call_tool(name, args):
    tgt = _target(args)
    if name == "chromeless_ping":
        return _text(json.dumps(ctl.request({"cmd": "ping"})))
    if name == "chromeless_windows":
        return _text(json.dumps(ctl.call("windows"), indent=2))
    if name == "chromeless_profiles":
        return _text(json.dumps(ctl.call("profiles"), indent=2))
    if name == "chromeless_open":
        # request() rather than call(): a needProfile reply carries the
        # profile list the agent must show its user — not an error to raise.
        out = ctl.request({"cmd": "open", "url": args["url"],
                           "window": args.get("window"),
                           "profile": args.get("profile")})
        if not out.get("ok") and not out.get("needProfile"):
            return _err(out.get("error", "open failed"))
        return _text(json.dumps(out))
    if name == "chromeless_navigate":
        return _text(json.dumps(ctl.call("navigate", url=args["url"], **tgt)))
    if name == "chromeless_evaluate":
        return _text(json.dumps(ctl.call("eval", js=args["js"], **tgt)))
    if name == "chromeless_screenshot":
        out = ctl.call("snap", base64=True, **tgt)
        png = out.get("png")
        if not png:
            return _err("no image returned")
        return {"content": [
            {"type": "image", "data": png, "mimeType": "image/png"},
            {"type": "text",
             "text": "%sx%s px — window %s tab %s" % (
                 out.get("width"), out.get("height"),
                 out.get("window"), out.get("tab"))}]}
    if name == "chromeless_click":
        return _text(json.dumps(ctl.click(args["selector"], **tgt).get("value")))
    if name == "chromeless_type":
        return _text(json.dumps(
            ctl.type_text(args["selector"], args["text"],
                          clear=args.get("clear", False), **tgt).get("value")))
    if name == "chromeless_press":
        return _text(json.dumps(ctl.press(args["key"], **tgt).get("value")))
    if name == "chromeless_wait_for":
        return _text(json.dumps(ctl.wait_for(args["js"], args.get("timeout", 10.0), **tgt)))
    if name == "chromeless_page_text":
        return _text(ctl.page_text(**tgt).get("value", ""))
    if name == "chromeless_logs":
        out = ctl.call("logs", kind=args.get("kind"), limit=args.get("limit"),
                       clear=args.get("clear") or None, **tgt)
        return _text(json.dumps(out.get("entries", out)))
    if name in ("chromeless_back", "chromeless_forward", "chromeless_reload",
                "chromeless_activate", "chromeless_close"):
        return _text(json.dumps(ctl.call(name.removeprefix("chromeless_"), **tgt)))
    return _err("unknown tool " + name)


def handle(msg):
    method = msg.get("method")
    if method == "initialize":
        return {"protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "chromeless", "version": "1.0.0"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": n, "description": d, "inputSchema": s}
                          for n, d, s in TOOLS]}
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name", "")
        if name not in _TOOL_MAP:
            raise JsonRpcError(-32602, "unknown tool " + name)
        try:
            return call_tool(name, params.get("arguments") or {})
        except ctl.ControlError as exc:
            return _err(str(exc))
        except Exception as exc:  # keep the server alive on a tool's bad day
            return _err("%s: %s" % (type(exc).__name__, exc))
    if method and method.startswith("notifications/"):
        return _SKIP
    raise JsonRpcError(-32601, "method not found: %s" % method)


class JsonRpcError(Exception):
    def __init__(self, code, message):
        self.code = code
        self.message = message


_SKIP = object()


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "id" not in msg:
            continue  # a notification — never answered
        try:
            result = handle(msg)
            if result is _SKIP:
                continue
            reply = {"jsonrpc": "2.0", "id": msg["id"], "result": result}
        except JsonRpcError as exc:
            reply = {"jsonrpc": "2.0", "id": msg["id"],
                     "error": {"code": exc.code, "message": exc.message}}
        out.write(json.dumps(reply) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
