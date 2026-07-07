# Multi Profiles Plan

## Goal

Add profile support so Chromeless can run separate browser identities side by side.

Primary use case:

- Log in to multiple Google accounts at the same time.
- Log in to multiple OneDrive/Microsoft accounts at the same time.
- Keep each account's cookies, cache, local storage, history, and active sessions separate.

Opening a new window should let the user choose which profile to use.

## Product Shape

Chromeless should stay minimal:

- No permanent profile sidebar.
- No tab UI.
- No heavy settings screen for the first version.
- A small native profile picker is enough.

Expected flow:

1. User presses `Cmd+N`.
2. A native picker appears with profiles.
3. User chooses a profile.
4. A new Chromeless window opens using that profile's isolated web data.

If no profiles exist, create a default profile automatically.

## Profile Data Model

Each profile should have:

- Stable ID: machine-friendly folder name, for example `default`, `work`, `personal`, or a UUID.
- Display name: user-facing name, for example `Personal`, `Work`, `Google A`, `OneDrive Client`.
- WebKit data store directory.
- Optional last URL.
- Optional window frame.
- Optional created/updated timestamp.

Suggested profile metadata file:

```text
~/Library/Application Support/Chromeless/Profiles/profiles.json
```

Suggested per-profile folders:

```text
~/Library/Application Support/Chromeless/Profiles/<profile-id>/
~/Library/Application Support/Chromeless/Profiles/<profile-id>/WebKit/
```

Example metadata:

```json
{
  "profiles": [
    {
      "id": "default",
      "name": "Default",
      "lastURL": "https://example.com"
    },
    {
      "id": "work",
      "name": "Work",
      "lastURL": "https://onedrive.live.com/"
    }
  ]
}
```

## WebKit Isolation

Each profile needs its own `WKWebsiteDataStore`.

Use a persistent, profile-specific data store if available on the deployment target:

```swift
let store = WKWebsiteDataStore(forIdentifier: profile.identifier)
configuration.websiteDataStore = store
```

If the exact initializer is not available for the current macOS target, use the closest supported WebKit API for isolated persistent website data. Avoid `WKWebsiteDataStore.default()` because it shares cookies/cache/session across all profiles.

Do not use `WKWebsiteDataStore.nonPersistent()` for normal profiles because sessions would disappear after restart.

Profile isolation should cover:

- Cookies
- Cache
- Local storage
- IndexedDB
- Service workers
- Login sessions

## App Changes

### 1. Add Profile Type

Add a small model near launch options:

```swift
struct BrowserProfile: Codable, Identifiable {
    let id: String
    var name: String
    var lastURL: String?
}
```

Keep it simple for the first version.

### 2. Add Profile Store

Create a `ProfileStore` helper responsible for:

- Loading `profiles.json`.
- Creating the default profile if missing.
- Saving profile metadata.
- Creating profile folders.
- Sanitizing user-entered profile names into stable IDs.

Suggested API:

```swift
final class ProfileStore {
    var profiles: [BrowserProfile]

    func load()
    func save()
    func createProfile(named name: String) throws -> BrowserProfile
    func updateLastURL(_ url: URL, for profile: BrowserProfile)
}
```

For a single-file app, this can live inside `main.swift` at first.

### 3. Pass Profile Into Windows

Change `BrowserWindowController` initializer from:

```swift
init(url: URL?, size: NSSize?, snap: SnapJob?, isPrimary: Bool)
```

to:

```swift
init(profile: BrowserProfile, url: URL?, size: NSSize?, snap: SnapJob?, isPrimary: Bool)
```

Store the profile on the controller:

```swift
private let profile: BrowserProfile
```

Use the profile when creating `WKWebViewConfiguration`.

### 4. Configure WKWebView Per Profile

Before creating the `BrowserWebView`, assign the data store:

```swift
let conf = WKWebViewConfiguration()
conf.websiteDataStore = websiteDataStore(for: profile)
```

Keep all existing settings:

- Element fullscreen
- Autoplay
- AirPlay
- Safari user agent
- Passkey fallback script

### 5. Save Last URL Per Profile

Replace the global `UserDefaults` `LastURL` with profile metadata:

Current behavior:

```swift
UserDefaults.standard.set(u.absoluteString, forKey: "LastURL")
```

New behavior:

```swift
profileStore.updateLastURL(u, for: profile)
```

This prevents one profile's last page from affecting another.

### 6. Profile Picker On New Window

Change `Cmd+N` behavior:

```swift
@objc func newWindow(_ sender: Any?) {
    chooseProfileThenOpenWindow()
}
```

Use a native `NSAlert` or small `NSPanel` for the first version.

Minimum picker features:

- List existing profiles.
- Open selected profile.
- Button to create a new profile.
- Cancel.

Suggested UI:

- `NSAlert`
- `NSPopUpButton` containing profile names
- `New Profile...` button
- `Open` button

For profile creation:

- Show another `NSAlert` with an `NSTextField`.
- Create the profile.
- Immediately open a window with it.

### 7. Startup Profile Choice

Recommended first behavior:

- On app launch, open the default profile automatically.
- On `Cmd+N`, ask which profile to use.

Optional later behavior:

- Add `--profile <name-or-id>` CLI option.
- Add `--profile-picker` CLI option.
- Remember last used profile.

### 8. Window Title

Because there is no visible browser chrome, include the profile name in the native window title:

```swift
window.title = "\(pageTitle) - \(profile.name)"
```

The title is mostly visible in Mission Control, app switcher, and window menus.

Avoid adding always-visible profile labels inside the page area unless users need it.

### 9. Downloads And Snapshots

Downloads should inherit the active profile automatically because they originate from that profile's `WKWebView`.

For CLI snapshot mode:

- Default to the default profile.
- Later add `--profile <id>` so users can snapshot an authenticated page from a specific profile.

Example future command:

```sh
./Chromeless.app/Contents/MacOS/Chromeless --profile work https://onedrive.live.com --snap page.png
```

## CLI Options

First version can skip CLI profile selection.

Recommended follow-up:

```text
--profile <id-or-name>  open using a specific profile
--profiles             list profiles and exit
```

Rules:

- If `--profile` does not exist, print a clear error.
- If no profile is specified, use `default`.
- `--snap` should use the requested profile if provided.

## Storage Migration

Current app uses:

```text
~/Library/WebKit/com.chromeless.app/
```

and global defaults:

```text
com.chromeless.app LastURL
```

Migration options:

### Simple First Version

Do not migrate existing cookies/cache automatically.

Behavior:

- Create `Default` profile.
- Start fresh profile storage.
- Existing WebKit data remains untouched.

This is safest and easiest.

### Later Migration

Offer a one-time "Import existing session into Default profile" path.

Only do this after verifying WebKit's storage layout and supported APIs. Blindly copying WebKit data folders can corrupt sessions or fail silently.

## Testing Checklist

Manual tests:

- Launch app: default profile opens.
- Press `Cmd+N`: profile picker appears.
- Create `Google A` profile.
- Create `Google B` profile.
- Log in to different Google accounts in each profile.
- Close and reopen each profile: each remains logged into the correct account.
- Repeat with OneDrive/Microsoft accounts.
- Clear one profile's cookies manually or via future UI: other profiles remain untouched.
- Download a file from profile A: download works and does not affect profile B.
- Snapshot mode still works with default profile.
- `Esc` returns to start page only for the current window/profile.

Regression tests:

- `Cmd+L` still opens the HUD.
- `Cmd+N` no longer opens a blank unprofiled window.
- `Cmd+W` closes only the current window.
- Back/forward remains per window.
- Cookies are not shared between profiles.

## Risks

- WebKit persistent custom data store APIs vary by macOS version.
- Passkeys/WebAuthn may have extra restrictions across custom data stores.
- Some identity providers detect unusual embedded browser behavior.
- Multiple Microsoft/Google logins may still share OS-level SSO outside WebKit in some flows.
- Migrating existing cookies/cache is risky and should not be done casually.

## Recommended First Patch

Keep the first implementation small:

- Add `BrowserProfile`.
- Add `ProfileStore`.
- Create a default profile automatically.
- Use profile-specific `WKWebsiteDataStore`.
- Pass profile into every `BrowserWindowController`.
- Save last URL per profile.
- Change `Cmd+N` to show a profile picker.
- Support creating a new profile from the picker.
- Leave migration, profile deletion, renaming, and CLI profile flags for later.

This gives the main value immediately: separate Google and OneDrive sessions in separate Chromeless windows.
