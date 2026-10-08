# multi-account-google-chat-mac

A small native macOS app for Google Chat with **several Google accounts signed
in at once**, in one window. A Slack-style rail on the left switches between
accounts ("workspaces"); each one keeps its own isolated login.

It is a tiny WKWebView host (`ChatApp.swift`) compiled with `swiftc` -- no
Xcode project, no dependencies.

## Features

- **One window, one rail button per workspace** (its logo, or the first letter
  of its name). Click to switch; the active workspace's name shows in the title
  bar.
- **Isolated login per workspace.** Each web view is backed by its own
  persistent store (`WKWebsiteDataStore(forIdentifier:)`), so every account
  stays signed in independently.
- **Unread dots.** A dot on a workspace's rail button when it has unread, and a
  dot on the Dock icon (also shown in cmd+tab) if any workspace does. Google
  Chat exposes no reliable total count, so the app mirrors Chat's own favicon
  "dot" signal -- the same thing that dots a browser tab.
- **Right-click a rail button** to move the workspace up or down, or to change
  or reset its logo. Order and custom logos are remembered (logos live in
  `~/Library/Application Support/<bundle-id>/logos/`, so they survive rebuilds).
- **Keyboard shortcuts**: Cmd+1..9 switch workspace, Cmd+Shift+[ / ] step
  through them, Cmd+R reloads, Cmd+= / Cmd+- / Cmd+0 zoom (saved per
  workspace), Cmd+W hides the window. The app reopens on the last workspace.
- **Unread counts and notifications.** The rail and Dock show unread counts
  read from Chat's sidebar (a plain dot when Chat shows no number). Chat
  delivers its own alerts by Web Push, which an embedded WKWebView cannot
  receive, so the app watches the conversation list instead: when a
  conversation's last-activity time moves and Chat marks it with a
  notification (DMs, @mentions -- Chat's own rules), it posts a macOS banner
  with the conversation name and, when Chat's Home list shows one, the message
  preview, and bounces the Dock icon once. Clicking the banner opens that
  conversation. This reads Chat's page markup, so it is best effort; if it
  stops matching, banners fall back to a generic "New message".
- **Attachments**: the upload button opens a file picker; downloads save to
  ~/Downloads.
- **Image attachments open in their own window**, centered and scaled to fit on
  a dark backdrop. **Esc** or **Cmd+W** closes it.
- **External links open in your default browser**, with Google's redirect
  wrapper stripped so you skip the "Redirect Notice" page.
- **Standard Edit menu**, so copy/paste/undo shortcuts work.
- **Presents the installed Safari's user agent**, so Google neither flags an
  "insecure browser" nor shows "This browser version is no longer supported".

## Setup

```sh
cp workspaces.example.conf workspaces.conf    # then edit it
./build-combined.sh                           # -> ~/Chats.app
open ~/Chats.app
```

Sign in once in each workspace. Logins survive rebuilds.

### workspaces.conf

One workspace per line. The file is gitignored, so your accounts and logos stay
local.

```
# name | url | icon | store-uuid
Work     | https://chat.google.com/ | icons/work.png
Personal | https://chat.google.com/
```

Only `name` and `url` are required:

- `icon` -- a PNG logo, ideally square with a transparent background. Relative
  paths resolve against the config file's directory, so drop logos in `icons/`
  (also gitignored). Without one, the rail shows the name's first letter.
- `store-uuid` -- the workspace's isolated data store, i.e. its login. Defaults
  to a UUID derived from the name.

The store UUID must stay constant across rebuilds or that workspace's login
resets. With the default, that means **renaming a workspace signs it out**; pin
an explicit UUID (`uuidgen`) if you expect to rename.

### Build options

```sh
OUT_DIR=/Applications ./build-combined.sh                         # install location
APP_NAME="Work Chat" BUNDLE_ID=com.local.workchat ./build-combined.sh
CONFIG=/path/to/other.conf ./build-combined.sh
```

The app icon is drawn by `draw-app-icon.swift` (two overlapping chat bubbles on
a night-blue tile). `ICON_STYLE=logos ./build-combined.sh` composes it from the
workspace logos instead (one fills the card, two stack, three or more form a
grid). Either way it is converted to `.icns` with `sips` + `iconutil`, both of
which ship with macOS.

## Requirements

- macOS 14 or later (for the per-workspace isolated stores).
- Xcode command line tools for `swiftc`: `xcode-select --install`.
- The app is ad-hoc signed. On first launch you may need to right-click ->
  Open once to get past Gatekeeper.

## Notes

- If the Dock icon looks generic after a rebuild, `touch ~/Chats.app` or log
  out and back in to refresh the icon cache.
- Deleting the app does not delete the logins; WebKit keeps the stores under
  `~/Library/WebKit/<bundle-id>/`.

## License

MIT -- see [LICENSE](LICENSE).
