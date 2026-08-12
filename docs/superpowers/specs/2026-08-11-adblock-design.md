# Ad blocking — design

Chromeless blocks ads with WebKit's own content-blocker engine: filter rules are
compiled once into a `WKContentRuleList` and handed to every web view. No proxy,
no request interception, no third-party library — the same mechanism Safari
content-blocker extensions use.

## Goals

- Block ad and tracker requests out of the box, offline, with no setup.
- Let the user subscribe to large public filter lists (EasyList, EasyPrivacy,
  regional lists) and keep them fresh.
- Let the user write custom rules, and pick an element on a page to hide it.
- Turn blocking off per site, because some sites break when their ad frames go
  missing.

## Non-goals

- **YouTube ads.** They stream from the same host as the video, so a content
  rule cannot separate them. Skipping them means injecting JavaScript that
  clicks YouTube's own Skip button — fragile, and it breaks every time YouTube
  reshuffles its DOM. Out of scope.
- **A blocked-request counter.** WebKit reports nothing about what a content
  rule list blocked. Any number shown would be invented. The panel reports the
  number of *active rules* instead.
- **Scriptlet injection** (`#%#`, `#$#`, `##+js(...)`). Needs a script engine
  and a maintained scriptlet library; unsupported lines are counted and skipped.

## Architecture

Everything is filter text in AdBlock Plus syntax, and everything goes through
one converter:

```
built-in list      (embedded in the binary)   ─┐
subscriptions      (downloaded, cached)        ├─►  ABP → WebKit JSON converter
custom rules       (typed by the user)         │         │
element-picker     (`domain##selector`)       ─┘         ▼
                                          [block rules] + [@@ exceptions] + [allowlist]
                                                          │
                                            SHA-256 of the JSON = list identifier
                                                          │
                                     WKContentRuleListStore: look up, else compile
                                                          │
                                          attach to every live WKWebView
```

Rule order inside the compiled list matters and is fixed: **block rules, then
`@@` exception rules, then per-site allowlist rules.** WebKit's
`ignore-previous-rules` only cancels rules earlier in the *same* list, so the
allowlist has to be compiled in rather than kept separately.

### Files

| File | Contents |
| --- | --- |
| `AdBlockFilters.swift` | The built-in filter list, and the ABP → WebKit JSON converter. Pure functions, no state. |
| `AdBlock.swift` | `AdBlockStore` (settings on disk), `AdBlockManager` (compile, cache, attach, fetch, auto-update). |
| `AdBlockUI.swift` | Settings dialog, subscription editor, custom-rule editor, element picker. |

`main.swift` changes in four places: `makeWebConfiguration` attaches the list,
`configure(_ tab:)` registers the web view with the manager, the View menu gains
three items, and `AppDelegate` kicks off the first compile and the update check.
`build.sh` compiles the three new files.

### Storage

`~/Library/Application Support/Chromeless/AdBlock/`

```
adblock.json          settings, subscriptions, allowlist, custom rules
lists/<id>.txt        raw downloaded filter text, one file per subscription
```

Settings are **global**, shared by every profile. Profiles exist to separate
cookies and logins; an ad-blocking preference is not an identity.

```jsonc
{
  "enabled": true,
  "allowlist": ["example.com"],          // eTLD+1, blocking off for these
  "customRules": "||ads.example.com^\nexample.com##.promo",
  "subscriptions": [
    {
      "id": "easylist",
      "name": "EasyList",
      "url": "https://easylist.to/easylist/easylist.txt",
      "enabled": true,
      "updatedAt": "2026-08-11T09:00:00Z",
      "etag": "\"abc123\"",
      "ruleCount": 41892
    }
  ]
}
```

## The converter

Input is one filter line; output is zero or more WebKit rules.

### Network rules

| ABP | WebKit `url-filter` |
| --- | --- |
| `\|\|example.com^` | `^https?://([^/?#]*\.)?example\.com[/?#:]` |
| `\|http://example.com` | `^http://example\.com` |
| `example.com\|` | `example\.com$` |
| `/banner/*.gif` | `/banner/.*\.gif` |
| `/regex/` | passed through if it uses only the supported subset |

WebKit's URL filter accepts a restricted regex: `.`, `*`, `+`, `?`, `^`, `$`,
`[...]`, `[^...]`, `(...)`, and backslash escapes. It rejects `\d`, `\w`, `\b`,
`{n,m}`, lookahead, backreferences, **and alternation** — the generator never
emits them, and a `/regex/` rule containing one is skipped.

Alternation is the one that cost a debugging round: a single EasyList regex rule
containing `(club|bid|biz|…)` made WebKit answer *"Disjunctions are not supported
yet"* and fail the **entire** list, not just that rule. That is why
`--adblock-compiletest` exists — no amount of unit testing the converter can
predict which constructs WebKit's compiler will refuse.

ABP's separator `^` becomes `[/?#:&=;,]`, which requires a character to follow.
That is safe because WebKit matches against canonicalized URLs, where
`https://ads.com` already carries its `/`.

### Options

| ABP option | WebKit |
| --- | --- |
| `third-party` / `~third-party` | `load-type: ["third-party"]` / `["first-party"]` |
| `domain=a.com\|~b.com` | `if-domain: ["*a.com"]` / `unless-domain: ["*b.com"]` |
| `script`, `image`, `stylesheet`, `font`, `media`, `popup` | `resource-type`, mapped 1:1 |
| `xmlhttprequest`, `websocket`, `ping`, `object`, `other` | `resource-type: ["raw"]` |
| `subdocument`, `document` | `resource-type: ["document"]` |
| `~script` and friends | complement of the type set |
| `match-case` | `case-sensitive: true` |
| `important` | ignored (treated as a plain block) |
| `csp=`, `redirect=`, `removeparam=`, `badfilter`, `header=`, `replace=` | rule skipped, counted |

`if-domain`/`unless-domain` match the **top-level document's** domain in WebKit,
which is exactly what ABP's `domain=` means, so the mapping is direct.

### Cosmetic rules

`##selector` hides an element with `css-display-none`. Emitting one WebKit rule
per selector would spend tens of thousands of rules on EasyList alone, so
selectors sharing the same domain scope are merged into one rule with a
comma-separated selector list, in batches of 500 (a cap that keeps any single
selector string from growing unbounded).

- `example.com##.ad` → `if-domain: ["*example.com"]`
- `~example.com##.ad` → `unless-domain: ["*example.com"]`
- `##.ad` (generic) → no domain constraint
- `#@#` exceptions are **skipped and counted**. Honouring them would mean
  splitting the merged generic rule per domain, which costs more rules than the
  exceptions are worth. The per-site toggle covers the rare breakage.

### Limits and failure

WebKit caps a rule list at roughly 150 000 rules, and the converter uses that
number. Measured: EasyList, EasyPrivacy and ABPVN together convert to **114 479
rules** with nothing dropped, from 135 170 filter lines, of which 1 668 (1.2%)
could not be expressed. Rules are kept in priority order — built-in, custom and
picker rules, then subscriptions in list order — so a huge subscription can
never push the built-in rules out. Whatever gets dropped is **reported in the
panel**; it is never dropped silently.

If compilation fails anyway, the manager retries once with subscriptions
excluded (built-in + custom only) and surfaces the error. Blocking degrades, it
does not vanish.

## Applying the list

`AdBlockManager` holds the compiled `WKContentRuleList` and a weak set of every
live `WKWebView`. `makeWebConfiguration` attaches the current list if one is
ready; `configure(_ tab:)` registers the view. When a compile finishes, the
manager removes and re-adds the list on every registered view.

Compiling is cached by content hash, so the second time a given rule set is
needed — including toggling a site's allowlist entry back and forth — the list
comes from `WKContentRuleListStore` instantly. Stale identifiers are pruned
after every successful build.

### Why the identifier is also cached on disk

Hashing the JSON is only possible *after* converting 135 000 filter lines and
encoding 14 MB of JSON, which measures at several seconds. Paying that on every
launch just to discover the compiled list was already in WebKit's store left the
first ~8 seconds of every session unblocked — measured, not guessed.

So the last successful build's identifier is stored in `adblock.json` next to a
**fingerprint** of its inputs: the converter's version, the allowlist, a hash of
the custom rules, and the size and mtime of every enabled list file. When the
fingerprint still matches, the launch skips conversion entirely and goes straight
to `lookUpContentRuleList`. Measured after the change: blocking is live within
400 ms of page load.

A cold build — first run, or any change to the lists — still takes a few seconds
(4.4 s to compile 114 k rules), and pages loaded in that window are unblocked.
The manager reloads nothing on its own for that case: reloading a page out from
under the user to catch a few early requests is worse than missing them.

## User interface

Three items in the View menu:

| Item | Key | Behaviour |
| --- | --- | --- |
| Block Ads on This Site | `⇧⌘B` | Checkbox. Toggles the current page's eTLD+1 in the allowlist, recompiles, reloads the tab. |
| Pick Element to Block… | `⌃⇧⌘E` | Starts the element picker in the active tab. |
| Ad Blocking… | — | Opens the settings dialog. |

The settings dialog follows the profile picker's precedent — `NSAlert` with a
table in its accessory view, not a floating HUD. Downloads is a HUD because it
reports transient status; this is a management screen.

It lists subscriptions with an enable checkbox, rule count, and last-update
time, plus buttons for **Add List…**, **Update Now**, **Custom Rules…**,
**Allowed Sites…**, and a status line: `N rules active · M dropped over the
cap · updated 2 hours ago`.

### Element picker

`⌃⇧⌘E` injects an overlay script into the active tab:

- A translucent box tracks the element under the pointer, with its generated
  selector in a label.
- `↑`/`↓` widen the selection to the parent or narrow it back.
- Click confirms; `Esc` cancels.
- The chosen selector is posted to the native side over the
  `chromelessPicker` message handler, appended to custom rules as
  `<domain>##<selector>`, and the list recompiles.

The selector is built by preferring a stable `id`, then the element's tag plus
its non-generated class names, then an `:nth-of-type()` path up to five levels
deep. Class names that look generated — a hash-like run of hex, or a
CSS-modules suffix — are skipped, because they change on the site's next deploy.

Picker rules only hide; they do not stop the request. The banner disappears, the
bytes still arrive.

## Auto-update

Five seconds after launch (never during `--snap`), any enabled subscription
older than seven days is refetched with its stored `ETag`. A `304` just stamps
`updatedAt`. New content is written to `lists/<id>.txt` and triggers a recompile.
Failures are silent in the toast layer and visible in the settings dialog.

## Testing

- **`--adblock-selftest`** runs the converter over a table of known input lines
  and asserts the emitted regex and options, checks registrable-domain
  extraction, and encodes the built-in list. Cheap, and catches regressions in
  escaping and option parsing without a test framework the repo does not have.
- **`--adblock-compiletest`** converts every list actually installed and pushes
  the result through WebKit's own compiler. This is the one that finds real
  problems; the disjunction failure above was invisible to the unit checks.
- **A probe page** that loads scripts from four ad hosts plus one control host
  and reports which ones failed, screenshotted with `--snap`. Two lessons from
  building it: probe a URL that actually returns 200, because a 404 fires
  `onerror` and reads as "blocked"; and serve it over http, because a `file://`
  page has no domain and therefore never matches `$third-party` or
  `css-display-none`.

Verified this way: four ad hosts blocked with the control still loading, a
generic hiding rule applied, `⇧⌘B` unblocking everything on one site including
the hiding rules, and a `domain##selector` custom rule — the exact shape the
picker emits — taking effect.

## Phases

1. Converter, built-in list, compile/cache, allowlist, `⇧⌘B`, menu wiring.
2. Subscriptions: add/remove, fetch with `ETag`, weekly auto-update, settings
   dialog.
3. Element picker and the custom-rule editor.

Each phase leaves the app shippable.
