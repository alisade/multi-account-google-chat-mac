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

The app icon is composed from the workspace logos (one fills the card, two
stack, three or more form a grid) and converted to `.icns` with `sips` +
`iconutil`, both of which ship with macOS.

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
