# Download Management Design

## Goal

Chromeless can already download files: `WKDownloadDelegate` is wired up, undisplayable
responses and `Content-Disposition: attachment` become downloads, and an `NSSavePanel`
picks the destination. What it cannot do is *manage* them. There is no progress, no way
to cancel a download in flight, no record of what was saved or where, and no recovery
from a failure.

This design adds that management layer while keeping the app's promise: no permanent
chrome. The downloads UI occupies zero pixels until a download exists, and disappears
again when the work is done.

## Decisions

| Question | Decision |
| --- | --- |
| Where does the UI live | Floating overlay panel inside the window, bottom-right, toggled with ⌘⇧J |
| List scope | App-wide, shared across windows, tabs, and profiles |
| Persistence | In memory only; the list dies with the process |
| Destination | Auto-save to `~/Downloads`; hold ⌥ to get the save panel |
| Pause / resume | Yes |
| Retry after failure | Yes |
| Drag row to Finder | Yes |
| Code layout | New `Downloads.swift`, compiled alongside `main.swift` |

In-memory scope keeps the `plan-downloading.md` principle of "no persistent download
history" intact: closing Chromeless leaves nothing on disk to leak or clean up.

## Architecture

### New file

`Downloads.swift` holds `DownloadState`, `DownloadItem`, `DownloadManager`,
`DownloadsPanelView`, and `DownloadRowView`. `build.sh` changes one line:

```sh
swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  main.swift Downloads.swift \
  -o "$APP/Contents/MacOS/Chromeless" \
  -framework Cocoa -framework WebKit
```

No new dependencies, no Xcode project. `main.swift` stays around 1900 lines instead of
growing past 2300.

### Data model

```swift
enum DownloadState {
    case starting                              // destination not yet chosen
    case running
    case paused(resumeData: Data?)
    case finished(URL)
    case failed(message: String, resumeData: Data?)
}

final class DownloadItem {
    let id = UUID()
    let startedAt: Date
    var filename: String
    var destination: URL?
    var sourceRequest: URLRequest?             // for retry-from-scratch
    var download: WKDownload?                  // nil once finished or failed
    weak var origin: WKWebView?                // where to resume or retry
    var state: DownloadState
    var bytesReceived: Int64
    var bytesExpected: Int64                   // -1 when the server sends no length
    var wantsSavePanel: Bool                   // ⌥ was held at click time
}
```

### DownloadManager

A global `let downloadManager = DownloadManager()`, mirroring the existing
`let profileStore = ProfileStore()` at `main.swift:364`.

It owns `items: [DownloadItem]` newest-first and is **the** `WKDownloadDelegate` for
every download in the app. Public surface:

- `attach(_ download: WKDownload, from webView: WKWebView, wantsSavePanel: Bool)`
- `pause(_ item)` / `resume(_ item)` / `cancel(_ item)` / `retry(_ item)`
- `remove(_ item)` / `clearFinished()`
- `var hasActiveDownloads: Bool`

Changes are broadcast by posting `.downloadsDidChange` on `NotificationCenter`, which
avoids observer lifetime bookkeeping — panels subscribe in `init` and unsubscribe on
deinit.

Progress comes from KVO on `download.progress` (`completedUnitCount` /
`totalUnitCount`), coalesced to roughly 10 Hz. A fast download otherwise fires hundreds
of callbacks per second and thrashes layout for no visible benefit.

### Why the manager owns the delegate

`WKDownload.delegate` is a weak reference, and today it is the window controller
(`main.swift:1410`). Close that window mid-download and the download silently loses its
delegate: no destination callback, no completion, no failure. Moving the delegate to an
app-lived object is what makes the app-wide list actually work, and fixes that latent
bug on the way.

`BrowserWindowController` keeps only the policy decisions. Its two `didBecome download:`
methods collapse to a single forwarding call, and `activeDownloads`,
`cancelledDownloads`, and the four `WKDownloadDelegate` methods
(`main.swift:1415-1466`) move out entirely.

## Destination policy

Default is auto-save, matching Chrome and Safari:

1. Resolve a name from `suggestedFilename`, then `response.suggestedFilename`, then the
   URL's last path component, then `"download"`.
2. Sanitise it: strip path separators and leading dots so a hostile
   `Content-Disposition` cannot escape the directory.
3. Target `~/Downloads`. If the name is taken, insert a counter before the extension:
   `report.pdf` → `report-1.pdf` → `report-2.pdf`. This is done by probing
   `FileManager.fileExists`, so a race with another process is possible but harmless —
   WebKit fails that download and the row offers Retry.

Holding ⌥ when clicking the link opens the `NSSavePanel` instead. The modifier is read
from `navigationAction.modifierFlags` inside `decidePolicyFor navigationAction` and
stashed on the controller as `pendingDownloadWantsPanel`, consumed by the next
`didBecome download:`. Response-triggered downloads arrive after a network round trip,
so reading `NSEvent.modifierFlags` at destination time would be unreliable — the user
has usually released the key by then.

Cancelling the save panel drops the item from the list without a row, and shows a
`Download cancelled` toast.

## Panel UI

An `NSVisualEffectView` with `.hudWindow` material and a 14pt continuous corner radius,
matching the existing toast and HUD. It is a subview of the window's
`LayoutReportingView` container, positioned in `layoutOverlays()` at the bottom-right
with a 20pt margin, 380pt wide, and at most 320pt tall. Above ~5 rows it scrolls inside
an `NSScrollView`.

```
┌────────────────────────────────────────┐
│                                        │
│              web content               │
│              ┌───────────────────────┐ │
│              │ Downloads    Clear  ✕ │ │
│              ├───────────────────────┤ │
│              │ report.pdf            │ │
│              │ ▓▓▓▓▓▓▓░░░ 2.1/4.8 MB │ │
│              │            ⏸  ✕       │ │
│              ├───────────────────────┤ │
│              │ archive.zip      ✓    │ │
│              │ 18.2 MB · Reveal      │ │
│              └───────────────────────┘ │
└────────────────────────────────────────┘
```

Header: the word `Downloads`, a `Clear` text button that removes every finished and
failed row, and `✕` to dismiss the panel.

Each row is 56pt: filename at 13pt medium truncating the middle (so the extension stays
visible), a 3pt progress bar while running, and a secondary 11pt status line. Row
actions fade in on hover, following `ProfileChipView`'s existing hover idiom:

| State | Status line | Actions |
| --- | --- | --- |
| starting | `Starting…` | ✕ cancel |
| running | `2.1 MB of 4.8 MB` | ⏸ pause, ✕ cancel |
| running, unknown length | `2.1 MB` | ⏸ pause, ✕ cancel |
| paused, resumable | `Paused · 2.1 MB of 4.8 MB` | ▶ resume, ✕ cancel |
| paused, not resumable | `Paused · restarts from the beginning` (orange) | ▶ resume, ✕ cancel |
| finished | `4.8 MB · Downloads` | Reveal, ✕ remove |
| failed, resumable | the error message | Resume, ✕ remove |
| failed, not resumable | the error message | Restart, ✕ remove |

A finished row is an `NSDraggingSource`. Dragging it writes the destination `URL` to the
pasteboard, so dropping on Finder copies the file and dropping on another app opens it.
Double-clicking a finished row opens the file with `NSWorkspace.shared.open`.

### Visibility

- Auto-shows when a download starts, fading in over 0.15s to match the HUD.
- Auto-hides 4 seconds after the last active download reaches a terminal state, unless
  the pointer is inside the panel.
- ⌘⇧J toggles it at any time. Opened by hand it stays open until toggled again, and
  shows `No downloads yet` when the list is empty.
- Every window renders the same shared list, so the panel is in the same state wherever
  you toggle it.

### Toasts

Download toasts go away. The panel is now the feedback channel, and a toast that repeats
what the panel already shows is noise. The one exception is `Download cancelled` when the
user dismisses the save panel, because no row is ever created in that case.

## Pause, resume, retry

Pause calls `download.cancel(_:)` and keeps the returned `resumeData`. Resume calls
`WKWebView.resumeDownload(fromResumeData:completionHandler:)` on the item's `origin`,
falling back to the key window's active tab when that tab is gone. WebKit returns a new
`WKDownload`, which replaces the old one on the item.

WebKit only hands back `resumeData` when the server sent a validator (`ETag` or
`Last-Modified`) it can check the partial file against — range support alone is not
enough. Without one, pausing still works, but resuming has to throw the partial file
away and start over. That case is labelled rather than hidden: the row reads
`Paused · restarts from the beginning` in orange, so the user is not surprised by a
progress bar jumping back to zero.

The failed row names the action it will actually take: `Resume` when `resumeData`
survived, `Restart` when it did not. The status line always carries the real error from
`localizedDescription` — whether the transfer can pick up where it stopped is answered
by the button, not by guessing at the cause.

## Menu and shortcut

`View` gains `Show Downloads` with ⌘⇧J, wired to
`BrowserWindowController.toggleDownloadsPanel(_:)`. It sits after `Actual Size`, behind
a separator. No other menu changes.

## Quit protection

`applicationShouldTerminate` returns `.terminateLater` and presents an `NSAlert` when
`downloadManager.hasActiveDownloads` is true: *"A download is still in progress. Quit
anyway?"* Quitting cancels the downloads; cancelling the alert keeps the app running.

This matters more here than in most browsers, because
`applicationShouldTerminateAfterLastWindowClosed` is already `true`
(`main.swift:1562`) — closing the last window would otherwise silently kill a download
that is 90% done.

## Snapshot mode

Unchanged. `--snap` still exits non-zero via `exitForSnapDownload()` before any download
object is created, so the manager and panel never come into play and the CLI path stays
scriptable.

## Edge cases

- **Cancelling the save panel** — item dropped silently, `Download cancelled` toast.
- **Removing a running row** — cancels the download first, then removes the row.
- **Same file twice** — two rows, two files, unique names.
- **Server sends no `Content-Length`** — `bytesExpected` is -1; the progress bar becomes
  indeterminate and the status line shows only the bytes received.
- **Originating tab or window closed** — the download continues, because the manager
  holds the delegate. Resume falls back to another web view.
- **Destination deleted before Reveal** — `NSWorkspace` fails quietly; the row shows
  `File moved or deleted` on the next refresh.
- **Downloads across profiles** — one shared list. Rows carry no profile label, since
  the file lands in the same `~/Downloads` either way.

## Testing

The repo has no automated test harness, so this is verified by hand as the tab work was.

`python3 -m http.server` is not sufficient: it serves no `Range` support and no
validators, so pause always degrades to restart and the resume path never gets
exercised. The fixture needs a server that throttles (to leave time to click), honours
`Range`, and sends `ETag` plus `Last-Modified`.

Checklist:

1. Open a `.zip` or `.bin` URL — it saves to `~/Downloads` with no panel, and the
   downloads panel slides in showing live progress.
2. Panel auto-hides about 4s after the download finishes.
3. ⌘⇧J reopens it; the finished row is still listed with its size and `Reveal`.
4. ⌥-click a download link — the `NSSavePanel` appears; cancelling it shows the
   cancelled toast and leaves no row.
5. Download `big.bin`, hit ⏸ then ▶ — it resumes rather than restarting (watch the byte
   count continue).
6. Download `big.bin`, kill the Python server mid-transfer — the row fails; restart the
   server and hit Retry.
7. Cancel a running download with ✕ — the row disappears and the partial file is gone.
8. Reveal opens Finder with the file selected; double-click opens it; dragging the row
   to a Finder window copies it.
9. Start a download in window A, open window B — both panels show the same row.
10. Start a download, close its window — the download completes and is still listed in
    another window's panel.
11. Start a download and press ⌘Q — the quit warning appears.
12. Download the same file twice — `file.txt` and `file-1.txt`.
13. `--snap` against a URL that forces a download still exits non-zero with the existing
    stderr message.
14. Open a PDF that WebKit can display — it renders inline, no download, no panel.

## Out of scope

Persistent history across launches, a download speed readout, bandwidth limiting,
per-profile download directories, a preference for the default destination, and a
context-menu "Download Linked File" item. Each is a small addition on top of this
design if it turns out to be wanted.
