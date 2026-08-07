# Tab support for chromeless

## Goal

Add multiple tabs per window while preserving the app's premise: the window is the
webpage. A window that holds one tab must look and behave exactly as it does today.

## Design decisions

| Decision | Choice |
| --- | --- |
| Tab bar visibility | Always visible, **except** hidden when the window holds one tab |
| Profile scope | All tabs in a window share the window's profile |
| Profile control | Merged into the tab bar, clickable, opens the profile picker |
| Session restore | None — tabs live for the session only; `--restore` keeps today's single-page behaviour |
| Tab reordering | Not in v1 |
| Native macOS tabs | Not used; `window.tabbingMode` stays `.disallowed` |

## Architecture

Today `BrowserWindowController` owns exactly one `let webView: BrowserWebView`, and
per-page state (`onStartPage`, `lastProgress`, `observations`) lives on the controller.

Introduce a `Tab` class that owns one web view plus its per-page state:

```
BrowserWindowController          1 window = 1 profile
├── tabs: [Tab]
├── activeIndex: Int
├── tabBar: TabBarView           34 pt, top edge, hidden when tabs.count == 1
└── overlays: HUD, toast, progress bar, profile chip
```

```
Tab (final class)
├── webView: BrowserWebView
├── onStartPage: Bool
├── lastProgress: CGFloat
├── title: String
└── observations: [NSKeyValueObservation]
```

The controller exposes `webView` as a computed property returning the active tab's
web view. Every existing menu action, HUD commit, snapshot, and download path keeps
working unchanged, because they all reach the page through `webView`.

Only the active tab's web view sits in the view hierarchy. Switching tabs removes the
outgoing view and inserts the incoming one. Background tabs stay alive and keep
loading; they are never torn down until closed.

All tabs in a window share the profile's `WKWebsiteDataStore`, so a login in one tab
is visible in the others.

### State that moves from controller to Tab

- `onStartPage` — each tab tracks whether it is showing the start page, so `Esc`
  escapes only the active tab.
- `lastProgress` and the progress observation — the progress bar reflects the active
  tab only.
- The title observation — the window title follows the active tab.

### State that stays on the controller

`snapJob`, `activeDownloads`, `cancelledDownloads`, the mouse monitor, and every
overlay stay at window level. Downloads are a window-level concern and a download
started in one tab must survive switching away from that tab.

## Tab bar

An `NSVisualEffectView` with material `.hudWindow`, matching the existing HUD and
toast so the bar reads as part of the same dark, borderless surface.

- Height 34 pt, pinned to the top edge, spanning the full window width.
- **78 pt left inset.** The traffic lights are hidden but appear on hover over the
  top-left corner (`installMouseMonitor`, main.swift:578). Without the inset they
  would draw on top of the first tab.
- Each tab item shows a truncated title and a ✕ button that appears on hover.
- A `+` button follows the last tab.
- Tab widths shrink as tabs are added, with a 90 pt floor; past that the row clips.
- The active tab is distinguished by a lighter background fill.
- The progress bar moves to sit directly below the tab bar when the bar is visible.

### Profile chip

One control, repositioned rather than duplicated:

- Tab bar visible → the chip sits at the right end of the tab bar.
- Tab bar hidden → the chip floats at the top-right corner, exactly as today.

Clicking it opens the profile picker, the same picker `⌘N` opens.

This removes the `hitTest` override on `PassthroughVisualEffectView` (main.swift:452),
which currently makes the badge click-through. Making the chip clickable is the point,
so the roughly 72×24 pt corner it occupies stops passing clicks to the page.

## Keyboard and menus

| Keys | Action |
| --- | --- |
| `⌘T` | New tab, opens the start page |
| `⌘W` | Close tab; closes the window when it is the last tab |
| `⇧⌘W` | Close window and all its tabs |
| `⌘1`…`⌘8` | Jump to the nth tab |
| `⌘9` | Jump to the last tab |
| `⌃Tab` / `⌃⇧Tab` | Next / previous tab, wrapping |
| `⇧⌘]` / `⇧⌘[` | Next / previous tab |

None of these collide with the existing bindings (`⌘L`, `⌘P`, `⌘R`, `⇧⌘R`, `⌘[`, `⌘]`,
`⌘=`, `⌘-`, `⌘0`, `⇧⌘S`, `⇧⌘C`, `⌃⌘F`, `⌘N`).

Menu changes:

- **File** gains "New Tab" (`⌘T`); "Close Window" (`⌘W`) becomes "Close Tab" (`⌘W`)
  with "Close Window" moving to `⇧⌘W`.
- **Window** gains "Show Next Tab", "Show Previous Tab", and the numbered tab jumps.

`⌃Tab` is not a menu key equivalent on macOS, so it is handled by a local key monitor
on the window controller.

## Behaviour changes to existing features

- `createWebViewWith` (main.swift:1064) currently loads `target=_blank` in place with
  the comment "No tabs, no popups". It now opens a new foreground tab. The comment
  is removed.
- `⌘drag` to move the window is unchanged, which means ⌘-click cannot open a
  background tab — ⌘-click never reaches the page (main.swift:430).
- `Esc` to escape to the start page acts on the active tab only.
- `⇧⌘S` snapshots the web view, so the tab bar never appears in a snapshot.
- Middle-click to open a link in a new tab is out of scope.

## Closing rules

- Closing the active tab activates the tab to its right, or the one to its left when
  the closed tab was last.
- Closing the only tab closes the window, which preserves today's `⌘W` muscle memory.
- Closing a window tears down all its tabs, removing every observation and releasing
  every web view.

## Error handling

Unchanged from today. Navigation failures, download failures, and JavaScript panels
stay window-level and surface through the existing toast. A failed load in a
background tab does not raise a toast, because the toast reports on the active page;
the tab simply shows its error state when activated.

## Testing

The app has no test target and is a single Swift file built by `build.sh`. Verify by
building and driving the app:

1. Build cleanly with `./build.sh`.
2. One tab shows no tab bar; the window is pixel-identical to the current build.
3. `⌘T` reveals the bar; closing back down to one tab hides it again.
4. Tabs keep loading in the background — start a video in tab 1, switch to tab 2, and
   confirm audio continues.
5. A login in one tab is visible in another tab of the same window, and absent from a
   window on a different profile.
6. `⌘W` on the last tab closes the window; `⇧⌘W` closes a multi-tab window outright.
7. Hovering the top-left corner reveals traffic lights that do not overlap the tabs.
8. The profile chip opens the picker in both the docked and floating position.
9. `⇧⌘S` produces a snapshot with no tab bar in it.
10. `--snap` and `--profiles` still work from the command line.

## Documentation

The start page (main.swift:371) and the README key table both list every keystroke and
must gain the tab bindings. The README's "no tabs" framing in the opening line needs
rewording, since it is no longer accurate.
