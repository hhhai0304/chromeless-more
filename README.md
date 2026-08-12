# chromeless

**The browser that isn't there.** The window *is* the webpage — no toolbar, no address bar, and no tab bar until you ask for a second tab. Made for clean screenshots, fullscreen YouTube, dashboards, and anything else that deserves the whole window.

A native macOS app in one Swift file, built on WKWebView (the Safari engine). No Electron, no dependencies, ~630 KB built.

![chromeless start page](docs/chromeless.png)

## Build

```sh
./build.sh        # -> Chromeless.app
open Chromeless.app

# or run the binary directly
./Chromeless.app/Contents/MacOS/Chromeless
```

Requires the Xcode Command Line Tools (`xcode-select --install`). Optionally `mv Chromeless.app /Applications/`.

## Use

Everything is a keystroke (also listed on the start page and in the menu bar):

| Keys | Action |
| --- | --- |
| `⌘L` | Search or enter a URL (floating HUD) |
| `⌘drag` | Move the window from anywhere |
| `⌃⌘F` | Fullscreen (YouTube's own ⛶ button works too) |
| `⇧⌘S` | Snapshot the page as PNG → Desktop |
| `⌘P` | Pin the window above everything |
| `⌘[` / `⌘]` | Back / forward (two-finger swipe also works) |
| `Esc` | Bail out — back to the start page (`⌘[` returns) |
| `⌘=` `⌘-` `⌘0` | Zoom in / out / reset (pinch works too) |
| `⇧⌘C` | Copy the current URL |
| `⌘R` / `⇧⌘R` | Reload / reload ignoring cache |
| `⌘T` | New tab |
| `⌘W` / `⇧⌘W` | Close tab / close the whole window |
| `⌘1`…`⌘8` `⌘9` | Jump to the nth tab / the last tab |
| `⌃Tab` / `⌃⇧Tab` | Next / previous tab (`⇧⌘]` `⇧⌘[` too) |
| `⌘N` | New profile window |
| `⇧⌘B` | Block ads on this site — off turns the blocker off for that site only |
| `⌃⇧⌘E` | Pick an element on the page to hide for good |

The traffic-light buttons exist but stay invisible — hover the top-left corner to reveal them. The active profile name appears as a small chip in the top-right corner; click it to switch profiles. The window remembers its frame per profile. To reopen the last saved page on launch, start it with `--restore`.
Downloads use the native macOS save panel when a page requests a download or WebKit cannot display the file.

## Tabs

A window starts with one tab and no tab bar, so nothing changes until you press `⌘T`. From the second tab onward a thin bar appears at the top edge; close back down to one tab and it disappears again. Snapshots (`⇧⌘S`) capture the page only, so the bar never lands in a screenshot.

Every tab in a window shares that window's profile and its cookies. To run two accounts side by side, open a second window with `⌘N` instead. Links with `target="_blank"` and `window.open` popups open as tabs rather than taking over the page. Tabs are not saved between launches.

## Profiles

`⌘N` opens a small profile picker with a visible list of profiles, their last saved pages, and actions to open, make default, create, or delete a profile. Each profile gets separate WebKit website data, so you can keep different Google or OneDrive accounts signed in side by side. Profile names are shown in the top-right badge and in the native window title.

```sh
./Chromeless.app/Contents/MacOS/Chromeless --profiles
./Chromeless.app/Contents/MacOS/Chromeless --profile work https://onedrive.live.com
./Chromeless.app/Contents/MacOS/Chromeless --profile personal --restore
```

Persistent profile isolation uses WebKit's profile data stores on macOS 14+. On macOS 13, profile windows are isolated but private for the session because WebKit does not expose persistent custom data stores there.

The selected default profile is used when launching without `--profile`, opening URLs from Finder, or running `--restore` without an explicit profile. Profile metadata, the default profile id, last URLs, and lightweight history are stored at:

```text
~/Library/Application Support/Chromeless/Profiles/profiles.json
```

Deleting a profile asks for confirmation and removes its profile metadata plus WebKit website data. Close all windows using that profile before deleting it.

## Ad blocking

On by default, using WebKit's own content-blocker engine — the same mechanism
Safari content-blocker extensions use. Rules are compiled once into a
`WKContentRuleList` and matched inside WebKit's networking process, so blocking
costs nothing at page load. No proxy, no request interception, no extension.

Chromeless ships a small built-in list and subscribes to **EasyList**,
**EasyPrivacy**, and **ABPVN** on first launch, refreshing them weekly. Together
they compile to about 114,000 rules. **View → Ad Blocking…** manages
subscriptions, adds your own list URLs, edits your own filter rules, and lists
the sites you turned blocking off for.

- `⇧⌘B` toggles blocking for the site you are on. Some sites do break without
  their ad frames; this is the escape hatch.
- `⌃⇧⌘E` starts the element picker: hover to highlight, `↑`/`↓` to grow or
  shrink the selection, click to hide it for good, `esc` to cancel. The rule is
  saved as `domain##selector` in your own rules. Picked elements are hidden, not
  blocked — the bytes still arrive.
- Rules use AdBlock Plus syntax, so any list in that format can be added.

Settings live in `~/Library/Application Support/Chromeless/AdBlock/`, shared by
every profile.

Three things it deliberately does not do:

- **No YouTube ads.** They stream from the same hosts as the video, so no
  content rule can separate them.
- **No "N ads blocked" counter.** WebKit reports nothing about what it blocked,
  so any number would be made up. The panel shows active rules instead.
- **No scriptlet injection** (`##+js(...)`, `#%#`). Unsupported filter lines are
  counted and skipped — about 1.2% of EasyList and EasyPrivacy combined.

The first launch after a filter list changes spends a few seconds converting and
compiling; pages loaded in that window are not blocked. Afterwards the compiled
list is cached and blocking is live before the first request goes out.

## CLI

```text
usage: chromeless [url] [options]
  --snap <path>     load the page, save a PNG of it, and quit
  --size <WxH>      window size in points (e.g. 1440x900)
  --wait <seconds>  extra settle time before --snap (default 1.0)
  --restore         reopen the selected profile's last saved page
  --profile <name>  use a specific profile
  --profiles        list profiles and exit
  --adblock-selftest    check the filter converter and exit
  --adblock-compiletest convert every installed list and compile it for real
```

`--adblock-compiletest` is the one that matters when changing the converter: it
pushes the real lists through WebKit's compiler, which rejects constructs the
unit checks cannot know about.

## CLI screenshot mode

Chromeless doubles as a webpage-to-PNG tool:

```sh
./Chromeless.app/Contents/MacOS/Chromeless https://example.com --snap shot.png --size 1440x900
./Chromeless.app/Contents/MacOS/Chromeless localhost:3000 --snap dev.png --wait 3
./Chromeless.app/Contents/MacOS/Chromeless --restore
./Chromeless.app/Contents/MacOS/Chromeless --profile work --restore --snap work.png
```

It loads the page, waits for it to settle, writes a Retina PNG, and exits.

## Notes

- Cookies, cache, local storage, and login sessions persist per profile on macOS 14+.
- Downloads use the current window's profile session, so authenticated downloads work with the account logged in there.
- `--snap` also accepts `--profile`, which is useful for authenticated dashboards.

## Passkeys

Apple gates WebAuthn in WKWebView behind the restricted `com.apple.developer.web-browser.public-key-credential` entitlement, and macOS kills ad-hoc builds that claim it without an Apple-issued provisioning profile (verified: instant SIGKILL). Chromeless checks its own signature at runtime:

- **Default build (no entitlement):** the WebAuthn API is hidden, so sites feature-detect the absence and offer their fallbacks instead of a doomed passkey prompt. For Google, "Try another way" → **"Get a prompt on your phone"** signs you in with no password and no passkey — it's Google's own push approval, not WebAuthn.
- **Entitled build:** passkeys work natively via iCloud Keychain + Touch ID. To get there: join the Apple Developer Program, request the *Web Browser Public Key Credential* capability for your App ID (developer.apple.com → Certificates, Identifiers & Profiles → your identifier → Additional Capabilities, or Apple's capability request form), download a provisioning profile containing it, then:

  ```sh
  PROVISIONING_PROFILE=chromeless.provisionprofile \
  CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh
  ```

  The same binary detects the entitlement and stops hiding WebAuthn. macOS may show a one-time consent (System Settings → Privacy & Security lists passkey access for web browsers).
- Presents a Safari user agent; element fullscreen, autoplay, and AirPlay are enabled.
- First `⇧⌘S` may trigger the standard macOS prompt to allow Desktop access.
- Deliberately absent: tabs, find-in-page, history UI, extensions. That's the point.

## License

[MIT](LICENSE)
