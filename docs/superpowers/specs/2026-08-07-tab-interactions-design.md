# Tab Interaction Design

## Goal

Chromeless has tabs, but the tab bar only accepts two gestures: left-click to select and
a click on the `✕` to close. Everything a browser user reaches for by reflex is missing —
you cannot drag a tab to a new position, and the middle mouse button does nothing anywhere.

This design adds those reflexes: drag-to-reorder with live animation, middle-click to close
a tab, middle-click on empty tab bar space to open a new tab, and middle-click on a link to
open it in a background tab.

## Decisions

| Question | Decision |
| --- | --- |
| Drag feel | Live reorder — the dragged tab follows the cursor, neighbours slide aside |
| Drag out of the bar | Not supported; the tab is clamped inside the bar and returns on release |
| Cancel a drag | Esc reverts to the original order |
| When does middle-click close fire | On mouse *up*, and only if the cursor is still inside the tab |
| Middle-click on empty bar space | Opens a new tab |
| Middle-click on a link | Opens a background tab, via a page script — WebKit gives no native hook. `⌘`-click is unavailable: `⌘` belongs to window dragging |
| Tab reordering and web views | Reordering only permutes the `tabs` array; no `WKWebView` is touched |
| Window dragging while tabs are up | `window.isMovable = false`, with `performDrag` restoring it for `⌘`-drag and the empty strip |

## Prerequisite: `TabBarView.rebuild` must reuse its views

`TabBarView.rebuild(titles:activeIndex:)` (main.swift:656) currently destroys every
`TabItemView` and builds fresh ones on each call, and `refreshTabs()` (main.swift:849)
calls it on every selection, close, and reorder.

That blocks dragging outright. The drag begins in `TabItemView.mouseDown`, which calls
`onSelect?()` first, which reaches `refreshTabs()`, which calls `removeFromSuperview()` on
the very view the drag loop is holding. The drag would die on its first frame.

It is also already a latent bug. `rebuild` captures a literal `index` in each item's
`onSelect` / `onClose` closure:

```swift
item.onSelect = { [weak self] in self?.onSelect?(index) }
item.onClose  = { [weak self] in self?.onClose?(index) }
```

Those captures are only correct because the views are thrown away and rebuilt after every
mutation. The moment views survive a mutation, a stale index closes the wrong tab.

### The change

- `rebuild` adds or removes items to match `titles.count` and updates the survivors in
  place. Nothing is recreated when the count is unchanged.
- `TabItemView` gains a `var index: Int`, kept current by `rebuild`.
- Callbacks pass the view, not a number: `onSelect: ((TabItemView) -> Void)?`. `TabBarView`
  reads `item.index` at call time, so the index is always live.

Beyond enabling the rest of this design, reusing views removes the one-frame flicker where
the whole tab bar is torn down and re-added on every tab switch.

## Drag to reorder

### Handoff

`TabItemView.mouseDown(with:)` keeps its current behaviour — `onSelect?(self)` fires
immediately, so a tab activates on press the way it does in every other browser — then
hands the event to the bar:

```swift
override func mouseDown(with event: NSEvent) {
    onSelect?(self)
    onDragBegin?(self, event)
}
```

The bar owns the drag because the bar owns the layout and the sibling ordering. An item
cannot reposition its neighbours.

### The tracking loop

`TabBarView.beginDrag(item:event:)` records the grab offset (cursor x minus the item's
frame origin x, in bar coordinates) and the item's starting index, then runs:

```swift
window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                    timeout: .infinity, mode: .eventTracking) { event, stop in ... }
```

| Event | Handling |
| --- | --- |
| `.leftMouseDragged`, moved < 4pt from origin | Ignored. Below this threshold the gesture is still a click. |
| `.leftMouseDragged`, past threshold | Mark the drag live. Raise the item above its siblings (`addSubview(item, positioned: .below, relativeTo: addButton)`). Set `item.frame.origin.x` to `cursorX - grabOffset`, clamped to the bar's tab region. |
| Dragged item's left edge crosses into another slot | Move the entry to that index in `items` (remove and reinsert, matching `moveTab`), then animate every non-dragged item to its new slot over 0.12s via `animator().frame`. |
| `.keyDown` with keyCode 53 (Esc) | Restore the original `items` order, animate the dragged item home, stop the loop, report no reorder. |
| `.leftMouseUp` | Animate the dragged item to its slot. If the final index differs from the starting index, call `onReorder?(from:to:)`. Stop the loop. |

The 4pt threshold is what keeps an ordinary click from registering as a zero-distance drag.

`layout()` must skip the item currently being dragged. Without that guard, any layout pass
during the drag — a window resize, a title change, an `animator()` commit — snaps the
dragged tab back to its slot mid-gesture.

### Committing the order

`BrowserWindowController` gains:

```swift
func moveTab(from: Int, to: Int)
```

It removes and reinserts the entry in `tabs`, adjusts `activeIndex` so the same tab stays
active, and calls `refreshTabs()`. No `WKWebView` is created, destroyed, or reparented —
the active tab is still the active tab, just at a different position.

`activeIndex` adjustment, given a move from `f` to `t`:

- `activeIndex == f` → `activeIndex = t` (the moved tab was the active one)
- `f < activeIndex <= t` → `activeIndex -= 1` (a tab moved out from the left, past it)
- `t <= activeIndex < f` → `activeIndex += 1` (a tab moved in from the right, past it)
- otherwise unchanged

The `refreshTabs()` call is harmless now that `rebuild` reuses views: the items are already
in their final order and at their final frames, so it repaints nothing visible.

## The window-drag collision

The tab bar occupies the window's titlebar strip, and macOS registers that strip as a
window-drag region in the WindowServer, outside this process. A press on a tab therefore
starts a window drag at the same moment it starts a tab drag. Both run; the window slides
along with the cursor, and because the cursor keeps the same position *relative to the
window*, the dragged tab never moves at all.

This was found by running the app, not by reading code, and four plausible fixes were tried
and measured before one worked:

| Attempt | Result |
| --- | --- |
| `mouseDownCanMoveWindow = false` on `TabItemView` | No effect. The hit view was logged reporting `canMove=false` while the window moved anyway. |
| `hitTest` returning the tab so the press never reaches the transparent title label | No effect. |
| A `NSTextField` subclass returning `mouseDownCanMoveWindow = false`, so the label stops donating its own rect to the drag region | No effect. |
| `isMovableByWindowBackground = false`, both at window creation and toggled for the duration of the gesture | No effect. Also proves the culprit is not background dragging. |
| **`window.isMovable = false`** | **Works.** The window stays put and the tab tracks the cursor. |

A control test isolated the cause: dragging in the page area never moved the window, and
moving the tab bar 60pt down — out of the titlebar strip — made every fix unnecessary. The
strip is the problem, and `isMovable` is the only switch the WindowServer honours.

`isMovable` is therefore cleared exactly while the tab bar is up, in `refreshTabs`:

```swift
window?.isMovable = !tabBarVisible
```

Nothing is lost. `performDrag(with:)` still moves the window with `isMovable` false — this
was measured, not assumed — so:

- `⌘`-drag anywhere keeps working through the existing call in `BrowserWebView.mouseDown`.
- The empty part of the tab bar moves the window through a new `performDrag` in
  `TabBarView.mouseDown`, which is what browsers do anyway.
- With a single tab there is no tab bar, `isMovable` stays true, and the titlebar strip
  behaves exactly as it did before.

## Middle-click a tab to close it

`TabItemView` handles button 2 in the pair:

```swift
override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 { middleDownInside = true } else { super.otherMouseDown(with: event) }
}

override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2, middleDownInside else { return super.otherMouseUp(with: event) }
    middleDownInside = false
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClose?(self) }
}
```

Firing on mouse *up*, inside the same view that received the mouse *down*, is the macOS
convention for any destructive click: sliding off the control before releasing cancels it.
Closing on mouse down would make a mis-aimed press unrecoverable.

There is no conflict with `BrowserWebView.otherMouseUp` (main.swift:441), which claims
buttons 3 and 4 for back/forward. `TabItemView` is a sibling of the web view in the window's
content view, not a descendant, so the two never see each other's events.

## Middle-click empty tab bar space for a new tab

```swift
override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 { onNewTab?() } else { super.otherMouseUp(with: event) }
}
```

on `TabBarView`. Items are subviews of the bar, so a middle-click landing on a tab is
hit-tested to the `TabItemView` and never reaches the bar.

## Middle-click a link for a background tab

The `createWebViewWith` route this section originally proposed does not work, and the two
risks it flagged were both resolved by running the app. The results:

**WebKit does not deliver a navigation action for a middle-click on a link.** It never
calls `createWebViewWith`. It navigates the *current frame* instead — a middle-click on a
link replaced the page in the active tab, which is worse than doing nothing. The fallback
is therefore the implementation, not the contingency.

**A background tab loads fine without a superview.** Opening one with `activate: false`
leaves its web view outside the view hierarchy, and the page still loaded and reported its
title into the tab bar. No change to `refreshTabs` was needed.

### What ships

A user script injected at document start in every frame cancels the middle-click and
reports the href back:

```js
document.addEventListener("mousedown", swallow, true);   // suppress the navigation
document.addEventListener("auxclick", function (e) {     // report on release
  if (e.button !== 1) return;
  var a = anchor(e.target);
  if (!a) return;
  e.preventDefault();
  e.stopPropagation();
  window.webkit.messageHandlers.chromelessAuxClick.postMessage(a.href);
}, true);
```

Suppressing on `mousedown` and reporting on `auxclick` means the gesture only counts once
the button is released, and `anchor()` walks up from the event target so a click on a child
element of a link still finds the `<a>`.

`AuxClickRouter`, a single shared `WKScriptMessageHandler`, receives the message and routes
it by `message.webView` — it never needs to know which window or profile the page belongs
to. `BrowserWebView` gains an `onAuxClickLink` closure that `configure(_:)` points at
`addTab(url:activate: false)`.

Tab titles already update for inactive tabs: the `\.title` observation in `observe(_:)`
looks the tab up by identity and calls `tabBar.update(titleAt:to:)` regardless of which tab
is active.

### ⌘-click is not part of this

`BrowserWebView.mouseDown` (main.swift:434) claims `⌘`-click for dragging the window and
returns without calling `super`, so a `⌘`-click never reaches the page. Measured: it
produces no navigation, no new tab, and no window movement. `⌘`-click therefore cannot open
a background tab in this app, and `createWebViewWith` is left exactly as it was rather than
carrying an unreachable `background` branch.

## Out of scope

- Tearing a tab out of the bar into its own window, and dragging between windows.
- Dragging tabs between profiles.
- Any drag affordance for the `+` button or the profile chip.

## Testing

The app is an AppKit binary with no test target, so verification is manual: `./build.sh`,
run the app, and drive it with synthetic `CGEvent` mouse input while reading back the window
frame and screenshots of the tab bar. The window frame matters as much as the tab order —
the whole window-drag collision above is invisible if you only look at the tabs.

Results, all observed rather than assumed:

| # | Check | Result |
| --- | --- | --- |
| 1 | Click a tab — it activates | pass |
| 2 | Drag a tab across several neighbours — they slide aside, order follows the cursor, the same tab stays active | pass |
| 3 | The window does not move during a tab drag | pass — frame unchanged at every step |
| 4 | Drag a tab and press Esc — order reverts | pass |
| 5 | Middle-click a tab — it closes, the right tab stays active | pass |
| 6 | Middle-click a tab, slide off, release — nothing closes | pass |
| 7 | Middle-click empty tab bar space — a new tab opens | pass |
| 8 | Drag empty tab bar space — the window moves | pass |
| 9 | With one tab, drag the titlebar strip — the window moves as before | pass |
| 10 | Middle-click a plain link — one background tab, current tab neither switched nor navigated | pass |
| 11 | Middle-click a `target="_blank"` link — one background tab, not two | pass |
| 12 | A background tab loads and reports its title into the bar | pass |
| 13 | `⌘`-click a link | no effect — see above; `⌘` belongs to window dragging |

Not reachable, so not tested: middle-clicking the last remaining tab. The bar hides at one
tab, so there is nothing to click. `⌘W` still routes the last tab to `performClose`.
