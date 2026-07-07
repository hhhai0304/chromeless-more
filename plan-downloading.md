# Downloading Plan

## Goal

Add simple, native file downloading to Chromeless while keeping the app's core promise: no browser chrome, no tabs, no permanent downloads UI.

The first version should support the common cases users expect from a WKWebView browser:

- Links whose response cannot be displayed by WebKit.
- Links that explicitly request download behavior.
- Files opened from `target=_blank` or JavaScript navigation.
- A clear save destination chosen by the user.
- Lightweight progress and completion feedback.

## Current State

Chromeless currently cancels responses that WebKit cannot display:

```swift
func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if !navigationResponse.canShowMIMEType {
        showToast("Can’t display this file type")
        decisionHandler(.cancel)
        return
    }
    decisionHandler(.allow)
}
```

The app already has:

- Toast UI for short status messages.
- A minimal menu structure.
- `WKNavigationDelegate` and `WKUIDelegate` ownership in `BrowserWindowController`.
- No persistent sidebar, shelf, history, or downloads manager.

## Design Principles

- Keep downloads invisible until needed.
- Use native macOS save panels instead of inventing destination UI.
- Prefer WebKit's download APIs over manual URLSession downloads.
- Make the first version small and predictable.
- Avoid persistent download history.
- Do not add a toolbar or visible browser chrome.

## Implementation Plan

### 1. Adopt WKDownloadDelegate

Update `BrowserWindowController` to conform to `WKDownloadDelegate`.

Add a small in-memory download state:

```swift
private var activeDownloads: Set<ObjectIdentifier> = []
```

If progress reporting is desired later, replace this with a dictionary keyed by `ObjectIdentifier` that stores destination URL, observed progress, and display name.

### 2. Start Downloads From Navigation Actions

In `decidePolicyFor navigationAction`, detect download requests when available.

On modern macOS, `WKNavigationAction` exposes `shouldPerformDownload`. If true, return `.download`:

```swift
if navigationAction.shouldPerformDownload {
    decisionHandler(.download)
    return
}
```

Keep the existing non-web scheme handling before this check.

### 3. Start Downloads From Navigation Responses

Replace the current "Can't display this file type" cancellation with WebKit download handling:

```swift
if !navigationResponse.canShowMIMEType {
    decisionHandler(.download)
    return
}
```

This preserves the current behavior for displayable pages and adds downloads only where the page cannot be rendered.

### 4. Receive Download Objects

Implement the delegate callbacks that WebKit calls when a navigation becomes a download:

```swift
func webView(_ webView: WKWebView,
             navigationAction: WKNavigationAction,
             didBecome download: WKDownload) {
    download.delegate = self
}

func webView(_ webView: WKWebView,
             navigationResponse: WKNavigationResponse,
             didBecome download: WKDownload) {
    download.delegate = self
}
```

Track active downloads and show a toast:

```swift
activeDownloads.insert(ObjectIdentifier(download))
showToast("Download started")
```

### 5. Ask For Destination

Implement `WKDownloadDelegate` destination selection with `NSSavePanel`.

Suggested behavior:

- Use `suggestedFilename` when WebKit provides one.
- Fall back to the URL last path component.
- Fall back to `download`.
- Default location: Downloads folder.

Sketch:

```swift
func download(_ download: WKDownload,
              decideDestinationUsing response: URLResponse,
              suggestedFilename: String,
              completionHandler: @escaping (URL?) -> Void) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedFilename.isEmpty ? "download" : suggestedFilename
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    panel.canCreateDirectories = true

    panel.beginSheetModal(for: window!) { result in
        completionHandler(result == .OK ? panel.url : nil)
    }
}
```

If `window` is unavailable, fall back to `panel.begin`.

### 6. Finish And Failure Feedback

Add completion handlers:

```swift
func downloadDidFinish(_ download: WKDownload) {
    activeDownloads.remove(ObjectIdentifier(download))
    showToast("Download complete")
}

func download(_ download: WKDownload,
              didFailWithError error: Error,
              resumeData: Data?) {
    activeDownloads.remove(ObjectIdentifier(download))
    showToast("Download failed")
}
```

For a later version, keep `resumeData` and offer retry. Do not include that in the first pass unless needed.

### 7. Add A Menu Command For Current Page

Optional but useful: add `File > Download Linked File` later only if the app grows context menu support.

For the first pass, skip a visible menu command. Downloads should be triggered by page behavior, not by permanent UI.

### 8. Consider Context Menus Later

WKWebView's default context menu may already expose some system actions. If custom download actions are needed, implement a minimal contextual menu for links:

- Open link here.
- Copy link.
- Download linked file.

This should be a follow-up, because it adds more interaction surface than basic download support requires.

## Edge Cases

- User cancels the save panel: cancel the download quietly or show `Download cancelled`.
- Duplicate filenames: `NSSavePanel` handles overwrite confirmation.
- Authentication-protected downloads: WebKit should reuse the active web session.
- Blob URLs and generated files: verify behavior manually; WebKit download handling may vary by macOS version.
- Multiple simultaneous downloads: support them through separate save panels, but avoid adding a downloads shelf.
- Snapshot mode: if a navigation triggers a download while `--snap` is active, fail with a clear stderr message instead of showing a save panel.

## Snapshot Mode Handling

When `launchOptions.snap != nil`, downloads should not open interactive UI.

Suggested policy:

- If a navigation action or response becomes a download during `--snap`, print:

```text
chromeless: page attempted to download a file during --snap
```

- Exit with a non-zero status.

This keeps CLI mode scriptable.

## Testing Checklist

Manual tests:

- Open a direct PDF URL that WebKit can display: it should render normally.
- Open a `.zip` URL: it should show a save panel and download.
- Click an `<a download>` link: it should show a save panel and download.
- Click a link with `Content-Disposition: attachment`: it should download.
- Cancel the save panel: the app should remain usable.
- Complete a download: a toast should appear.
- Trigger a failed download: a failure toast should appear.
- Run `--snap` against a URL that forces a download: the process should exit non-zero with stderr.

Suggested local test server:

```sh
mkdir -p /tmp/chromeless-download-test
printf 'hello\n' > /tmp/chromeless-download-test/file.txt
cd /tmp/chromeless-download-test
python3 -m http.server 8999
```

For attachment behavior, use a tiny custom HTTP server that sets:

```text
Content-Disposition: attachment; filename="example.txt"
```

## Nice-To-Have Follow-Ups

- Progress toast for long downloads.
- Reveal in Finder after completion.
- Remember the last chosen download directory.
- Retry failed downloads when `resumeData` is available.
- Context-menu item for downloading linked files.
- Preference for auto-saving to Downloads without prompting.

## Recommended First Patch

Keep the first implementation constrained to `main.swift`:

- Add `WKDownloadDelegate`.
- Return `.download` for download-triggering navigation actions and undisplayable responses.
- Assign `download.delegate = self`.
- Show `NSSavePanel` for destination.
- Show toast on start, finish, failure, and cancellation.
- Add noninteractive failure behavior for `--snap`.

This should preserve the app's chromeless feel while making file downloads work in the places users naturally expect them.
