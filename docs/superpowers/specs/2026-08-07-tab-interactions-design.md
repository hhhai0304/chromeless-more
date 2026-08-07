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
| Middle-click on a link | Opens a background tab; `⌘`-click too, `⌘⇧`-click stays foreground |
| Tab reordering and web views | Reordering only permutes the `tabs` array; no `WKWebView` is touched |

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
| Dragged item's centre passes a neighbour's centre | Swap the two entries in `items`, then animate every non-dragged item to its new slot over 0.12s via `animator().frame`. |
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

`createWebViewWith` (main.swift:1522) already opens a new tab for link and `window.open`
navigations; it only lacks the notion of "background".

```swift
let shift = navigationAction.modifierFlags.contains(.shift)
let background = !shift && (navigationAction.buttonNumber == 1
                            || navigationAction.modifierFlags.contains(.command))
return addTab(url: nil, configuration: configuration, activate: !background).webView
```

`addTab` already takes `activate:` and leaves `activeIndex` alone when it is false, so no
signature change is needed. Tab titles also already update for inactive tabs — the
`\.title` observation in `observe(_:)` (main.swift:1155) looks the tab up by identity and
calls `tabBar.update(titleAt:to:)` regardless of which tab is active.

`⌘`-click becomes a background tab and `⌘⇧`-click a foreground one, matching Safari and
Chrome. Today both open a foreground tab.

### Two assumptions that must be verified by running the app, not by reasoning

**Does WebKit deliver a navigation action for a middle-click on a link?**
`WKNavigationAction.buttonNumber` exists and reports `1` for the middle button, but it is
not established that WebKit synthesises a link navigation from a middle-click inside a
plain `WKWebView` rather than dispatching a bare `auxclick` to the page and stopping there.
If `createWebViewWith` is never called, this feature does not work at all.

Fallback if it is not called: inject a user script that listens for `auxclick` with
`button === 1` on an anchor, calls `preventDefault()`, and posts the resolved `href` through
a `WKScriptMessageHandler`. The repo has **no** script message handler infrastructure today
— `makeWebConfiguration` only ever adds the WebAuthn-hiding script and never registers a
handler — so the fallback means building that infrastructure, and is materially more work
than the happy path.

**Does a background tab load without a superview?**
`refreshTabs()` only adds `activeTab.webView` to the container and removes every other
tab's web view. A tab opened with `activate: false` therefore has a web view with no
superview and no window when WebKit begins driving the load. This is expected to work —
WebKit throttles rendering and timers for off-screen views but does not block loading — but
it has to be confirmed with a real page.

Fallback if the load stalls: add the background tab's web view to the container positioned
below the active tab's, so it is in the hierarchy but fully covered, and let the next
`refreshTabs()` pull it back out.

Because both risks live in this one feature, it is sequenced **last** and kept separate, so
a failure here cannot block the three interactions above it.

## Out of scope

- Tearing a tab out of the bar into its own window, and dragging between windows.
- Dragging tabs between profiles.
- Any drag affordance for the `+` button or the profile chip.

## Testing

The app is an AppKit binary with no test target, so verification is manual, via `./build.sh`
and running the app. Each item below must be observed, not assumed:

1. Click a tab — it activates, no drag artefacts, no flicker in the bar.
2. Drag a tab left and right past several neighbours — neighbours slide aside, the order
   follows the cursor, releasing keeps the new order and the same tab stays active.
3. Drag a tab and press Esc — order reverts, the tab animates home.
4. Drag a tab far above, below, and outside the window — it stays clamped in the bar.
5. Drag an inactive tab — it activates on press, then reorders.
6. Middle-click a tab — it closes; the remaining tabs keep the right titles and the right
   tab stays active.
7. Middle-click a tab, slide off it, release — nothing closes.
8. Middle-click a tab, close down to one tab, middle-click again — the window closes, same
   as `⌘W` (`closeTab` already routes the last tab to `performClose`).
9. Middle-click empty tab bar space — a new tab opens.
10. Middle-click a link — a background tab opens, the current tab stays active, and the new
    tab's title appears in the bar once the page loads.
11. `⌘`-click a link — background tab. `⌘⇧`-click — foreground tab.
