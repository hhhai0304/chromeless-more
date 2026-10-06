# chromeless

macOS browser in plain Swift — no Xcode project, no package manager, no
dependencies, no test suite. Built on WKWebView.

## Build / verify

- `./build.sh` → `Chromeless.app`. Requires Xcode Command Line Tools.
- **Every `.swift` file must be listed explicitly in `build.sh`'s `swiftc`
  line** — new files are not picked up automatically, and the build still
  succeeds without them. Add new files there.
- Verification = a clean build plus running
  `./Chromeless.app/Contents/MacOS/Chromeless`. There is no lint or test
  command.
- Handy smoke test that needs no interaction:
  `chromeless <url> --snap /tmp/x.png --wait 2` (loads, screenshots, exits).
- `--adblock-compiletest` matters when touching `AdBlockFilters.swift`: it
  runs real lists through WebKit's compiler.

## Layout

- `main.swift` is the core and deliberately huge: windows, tabs, navigation,
  menus, HUD (`⌘L`), find-in-page, downloads panel, permissions, snapshots.
- Feature areas split out alongside it: `AI.swift`/`AIUI.swift` (sidebar +
  settings), `AdBlock.swift`/`AdBlockFilters.swift`/`AdBlockUI.swift`,
  `Downloads.swift`, `QuickAccess.swift`, `SiteTweaks.swift`,
  `SettingsUI.swift`, `Translate.swift`,
  `RemoteControl.swift`/`RemoteUI.swift`.
- `tools/` holds standalone helpers, not app code.
- State files live in `~/Library/Application Support/Chromeless/` and stay
  owner-only (`0600`) — keep that convention.
- Code comments explain *why*, not what — match the existing voice.

## Driving the running app (remote control)

- Launch with `--remote`, or toggle **View ▸ Remote Control…** (persisted,
  off by default).
- Control socket: `~/Library/Application Support/Chromeless/control.sock`,
  one JSON object per line each way. Command list: header comment of
  `RemoteControl.swift`.
- `tools/chromelessctl.py` is a ready CLI client
  (`windows · open · nav · eval · click · type · press · wait · snap · text ·
  html · logs · back · forward · reload · activate · close`);
  `tools/chromeless-mcp.py` exposes the same as MCP tools over stdio.
- Commands only reach **agent tabs** (`Tab.isAgent`) — tabs the socket
  opened, marked orange. The user's own tabs refuse them; `open` is the only
  way a tab becomes one, always background. `logs` reads a tab's
  console/errors/fetch/XHR feed (`AgentLog`, page-world probe on
  `chromelessAgentLog`).
