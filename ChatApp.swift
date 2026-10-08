import Cocoa
import Network
import ServiceManagement
import os
import UserNotifications
import WebKit

// A minimal Slack-style multi-workspace WebKit app. Info.plist's "Workspaces"
// array (each entry: Name, URL, StoreID (a UUID), Icon) drives a left rail with
// one button per workspace, each web view backed by its own isolated persistent
// data store (WKWebsiteDataStore(forIdentifier:), macOS 14+), so multiple Google
// accounts stay signed in at once in one window. Without "Workspaces" it falls
// back to a single web view on "AppStartURL" (default Google Chat).

// A popup window (image viewer, OAuth, target=_blank) that closes on Escape,
// matching the browser lightbox behavior users expect. Cmd-W and the title-bar
// close button work too via the standard responder chain.
final class PopupWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { performClose(nil) }   // 53 = Esc
        else { super.keyDown(with: event) }
    }
}

// Top-anchored flipped container so rail buttons lay out from the top down and
// stay pinned to the top as the window grows.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// One workspace = one site + its own web view + (in multi mode) its own isolated
// data store and rail button.
final class Workspace {
    let name: String
    let url: URL
    let host: String
    var storeID: UUID?
    var iconFile: String?
    var webView: WKWebView!
    var button: NSButton?
    var dot: NSView?
    var dotLabel: NSTextField?
    var unread = false
    var unreadCount = 0               // Chat's "Home" unread count; 0 if not shown
    var unreadReported = false        // first badge report seen (startup state)
    var lastPageNotification: Date?   // last banner raised by the page itself
    var lastBanner: [String: (text: String, count: Int, at: Date)] = [:]   // per conversation, for de-duplication
    var inbox: [(id: String, name: String, text: String, count: Int)] = []   // unread conversations, newest first
    var watcher: WKWebView?           // hidden Home view, for previews (Settings > Message previews)
    var watcherReported = false       // watcher's first badge report seen (its baseline)
    var watcherLastReport: Date?      // watcher's last badge report (it reports every 2 s while alive)

    // The hidden Home view is reporting from a signed-in Chat page. While it is
    // loading, off its host (signing in) or crash-looping, the visible view
    // reports instead.
    var watcherHealthy: Bool {
        guard let w = watcher, let url = w.url, url.host == host, url.path.hasPrefix("/app/"),
              let last = watcherLastReport else { return false }
        return Date().timeIntervalSince(last) < 30
    }
    var backgroundSince: Date?        // when it last left the screen, for "send back to Home"
    var markupMissing: Set<String> = []   // selectors already logged as not matching
    var crashes: [Date] = []          // recent web-process crashes, for reload backoff

    // Stable per-workspace key (survives reordering; the store UUID also
    // survives renaming when pinned in workspaces.conf).
    var key: String { storeID?.uuidString ?? name }

    init(name: String, url: URL) {
        self.name = name
        self.url = url
        self.host = url.host?.lowercased() ?? ""
    }
}

// Track the installed Safari's version so Google never sees a stale UA and
// shows "This browser version is no longer supported". Falls back to a recent
// version if Safari's Info.plist can't be read.
let safariVersion: String = {
    let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
    if let info = NSDictionary(contentsOf: plist),
       let v = info["CFBundleShortVersionString"] as? String {
        let parts = v.split(separator: ".")
        if let major = parts.first {
            return "\(major).\(parts.count > 1 ? parts[1] : "0")"
        }
    }
    return "26.0"
}()
// Breakage in Chat's markup degrades features silently (no names, no
// previews, no counts), so it is logged here. Watch with:
//   log stream --predicate 'subsystem == "<bundle-id>"'
let chatLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.local.chats", category: "chat-page")

let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"

// A menu-bar inbox entry: which workspace, which conversation.
final class InboxRef {
    let ws: Workspace
    let conv: String
    init(ws: Workspace, conv: String) { self.ws = ws; self.conv = conv }
}

// Loads a Google service's own page once, top-level, in a hidden web view that
// shares a workspace's data store, then discards itself. See warmUpCompanions.
final class CompanionWarmUp: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let host: String
    let done: (Bool) -> Void   // true when the service's own page loaded
    private var finished = false

    init(url: URL, store: WKWebsiteDataStore, userAgent: String?, done: @escaping (Bool) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        webView.customUserAgent = userAgent
        host = url.host ?? ""
        self.done = done
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
        // Sign-in redirects normally settle in a few seconds; never hang on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.finish("timeout") }
    }

    // Done once the page has landed back on the service itself. Anywhere else
    // (an SSO provider's sign-in page, say) waits for the timeout and fails.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.host == host { finish("ok") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish("fail") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish("fail")
    }

    private func finish(_ outcome: String) {
        guard !finished else { return }
        finished = true
        webView.stopLoading()
        done(outcome == "ok")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    var window: NSWindow!
    var container: NSView!
    var workspaces: [Workspace] = []
    var current: Workspace?
    var appHosts: Set<String> = ["chat.google.com"]
    var popupWindows = Set<PopupWindow>()
    var railContent: FlippedView?
    var downloads: [WKDownload: URL] = [:]   // in-flight download -> destination
    var notifFrames: [String: WKFrameInfo] = [:]   // page notification id -> frame that raised it
    var statusItem: NSStatusItem?          // menu-bar icon
    var pathMonitor: NWPathMonitor?
    var offlineSince: Date?
    var asleepSince: Date?
    var reloadWhenOnline = false           // woke while offline: reload once the network is back
    var railView: NSView?
    var warmUps: [String: CompanionWarmUp] = [:]   // in-flight companion warm-ups, by workspace key + host
    var panelRecoveries: [String: [Date]] = [:]     // recent panel recoveries, by workspace key + host
    var panelRetryPending: Set<String> = []         // panel bounced while its warm-up was already running
    var lastFullReload: Date?                       // wake/reconnect reloads, to avoid doing it twice
    var afterLoad: [ObjectIdentifier: () -> Void] = [:]   // run when that navigation finishes (Reply)

    // MARK: - Workspace config

    // Multi-workspace list from Info.plist "Workspaces", else a single workspace
    // from "AppStartURL" (the classic single-site app).
    func loadWorkspaces() -> [Workspace] {
        if let arr = Bundle.main.object(forInfoDictionaryKey: "Workspaces") as? [[String: Any]], !arr.isEmpty {
            return arr.compactMap { d in
                guard let name = d["Name"] as? String,
                      let urlStr = d["URL"] as? String,
                      let url = URL(string: urlStr) else { return nil }
                let ws = Workspace(name: name, url: url)
                ws.storeID = (d["StoreID"] as? String).flatMap { UUID(uuidString: $0) }
                ws.iconFile = d["Icon"] as? String
                return ws
            }
        }
        let s = (Bundle.main.object(forInfoDictionaryKey: "AppStartURL") as? String) ?? "https://chat.google.com/"
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Chat"
        return [Workspace(name: name, url: URL(string: s)!)]
    }

    // A link is "external" (open in the default browser) unless it belongs to a
    // workspace itself or to the Google login/asset infrastructure we must keep
    // in-session so sign-in and Chat's own navigation keep working.
    func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false   // mailto:, tel:, etc. -- let the web view/system handle
        }
        guard let host = url.host?.lowercased() else { return false }
        let keepInApp = appHosts.union(["accounts.google.com", "accounts.youtube.com", "mail.google.com"])
        if keepInApp.contains(host) { return false }
        if host.hasSuffix(".gstatic.com") || host.hasSuffix(".googleusercontent.com") { return false }
        return true
    }

    // Google Chat wraps outbound links in a redirector
    // (https://www.google.com/url?url=<real>...). Opened cold in a browser that
    // shows Google's "Redirect Notice" interstitial, so unwrap to the real
    // target before handing it off.
    func unwrap(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host == "www.google.com" || host == "google.com",
              url.path == "/url",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return url }
        for key in ["url", "q"] {
            if let value = items.first(where: { $0.name == key })?.value,
               let target = URL(string: value) {
                return unwrap(target)   // handle nested wrapping
            }
        }
        return url
    }

    func openExternally(_ url: URL) { NSWorkspace.shared.open(unwrap(url)) }

    // Without a menu bar, macOS has nowhere to match Cmd+C/V/X/A/Z key
    // equivalents, so copy/paste appear "broken" (e.g. when logging in).
    // Build the standard App + Edit menus so the shortcuts reach the web view.
    func setupMainMenu() {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "App"
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings\u{2026}", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(NSMenuItem.separator())
        for (title, action) in [("Launch at Login", #selector(toggleLaunchAtLogin(_:))),
                                ("Show in Menu Bar", #selector(toggleMenuBarIcon(_:)))] {
            appMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Send Test Notification",
                        action: #selector(sendTestNotification(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                 _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.tag = tag
        }
        let appearanceMenu = NSMenu()
        for (i, title) in ["System", "Light", "Dark"].enumerated() {
            add(appearanceMenu, title, #selector(setAppAppearance(_:)), "", tag: i)
        }
        viewMenu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "").submenu = appearanceMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        workspaces = loadWorkspaces()
        setupMainMenu()
        appHosts = Set(workspaces.map { $0.host }.filter { !$0.isEmpty })
        if appHosts.isEmpty { appHosts = ["chat.google.com"] }

        let frame = NSRect(x: 0, y: 0, width: 1240, height: 840)
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Chat"
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = name
        window.setFrameAutosaveName("MainWindow")
        window.delegate = self
        let root = NSView(frame: frame)
        window.contentView = root
        // Lay out from root.bounds, not the literal `frame`: setFrameAutosaveName
        // may have restored a larger saved window size, and root has already been
        // resized to it. Sizing from `frame` would leave the content anchored to
        // the bottom with a blank band on top (autoresizing only affects later
        // resizes, not this initial layout).
        let bounds = root.bounds

        let multi = workspaces.count > 1
        let railW: CGFloat = multi ? 64 : 0
        if multi { buildRail(in: root, width: railW, height: bounds.height) }

        container = NSView(frame: NSRect(x: railW, y: 0, width: bounds.width - railW, height: bounds.height))
        container.autoresizingMask = [.width, .height]
        root.addSubview(container)

        for ws in workspaces {
            let wv = makeWebView(for: ws)
            ws.webView = wv
            wv.frame = container.bounds
            wv.autoresizingMask = [.width, .height]
            wv.isHidden = true
            container.addSubview(wv)
            wv.load(URLRequest(url: ws.url))
        }
        if let first = workspaces.first { select(first) }

        window.center()
        window.makeKeyAndOrderFront(nil)

        if UserDefaults.standard.object(forKey: "ShowMenuBarIcon") as? Bool ?? true { installStatusItem() }
        applyAppearance()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new style is readable a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.applyAppearance() }
        }
        watchSleepAndNetwork()
        // Give Chat's side-panel companions their own sign-in up front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.workspaces.forEach { self?.warmUpCompanion($0, host: "calendar.google.com") }
        }
        // Refresh mute/quiet-hours state on the rail, menu bar and Dock.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.updateBadges() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sendBackgroundWorkspacesHome() }
        applyPreviewMode()

        // Esc closes a focused popup window even if the web content (e.g. a bare
        // image page) would otherwise swallow the keystroke. A local monitor sees
        // the event before the responder chain, so this is reliable.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53,   // 53 = Esc
               let win = self?.popupWindows.first(where: { $0.isKeyWindow }) {
                win.performClose(nil)
                return nil
            }
            return event
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerNotificationCategories()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Build a configured web view for a workspace. In multi mode each gets its
    // own isolated persistent store so multiple Google accounts coexist.
    func makeWebView(for ws: Workspace) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        if let id = ws.storeID {
            cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        } else {
            cfg.websiteDataStore = .default()            // classic single-app store
        }
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // Unread state and new-message detection, read from Chat's own page.
        //  - Has-unread: Chat swaps its favicon between "..._favicon_no_dot_..."
        //    and "..._favicon_dot_..." (what dots a browser tab).
        //  - Count: the sidebar's "Home shortcut, N unread message(s)" label.
        //  - New messages: every conversation row ([role=listitem][data-group-id],
        //    in the sidebar and the Home list) carries data-display-timestamp, its
        //    last activity. A row whose timestamp moves forward while it shows
        //    "N Notification(s)" -- Chat's own rule for what deserves an alert
        //    (DMs, @mentions, followed threads) -- is a new message. Its name is
        //    the row's first meaningful text; the Home list row also has a
        //    preview of the message ([jsname=ok3btb]).
        // Chat's real alerts arrive by Web Push, which WKWebView cannot receive
        // (see notifyShim), so this is how the app knows about new messages.
        // All of it depends on Chat's markup and English UI text, so it is best
        // effort: if a selector stops matching, that piece goes quiet (no name,
        // no preview, or no count) and the favicon dot still works.
        let unreadProbe = #"""
        (function(){
          var last = null;
          var seen = {};                 // conversation id -> last timestamp seen
          var seenAlerts = {};           // conversation id -> last "N Notifications" seen
          var startedAt = Date.now();
          var SKIP = /^(Active|Away|Busy|Do not disturb|Out of office|Offline|Unread|Pinned conversation|Space|Conversation|Meeting conversation|Group conversation|External|Muted|Now|Yesterday|Open in a pop-up|Options|Summarize|Close|Mark as read|Press tab.*|\d+|\d+ Notifications?|\d+ (min|mins|hr|hrs)|\d{1,2}:\d{2}( [AP]M)?)$/i;

          function nameOf(row) {
            var w = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
            for (var n = w.nextNode(); n; n = w.nextNode()) {
              var t = n.nodeValue.trim(), el = n.parentElement;
              if (!t || SKIP.test(t)) continue;
              if (el.closest('button, i, [role=tooltip], [jsname=ok3btb]')) continue;
              return t;
            }
            return '';
          }

          // A row's own visible "Unread" label -- a text node that is exactly
          // "Unread", not part of a name or a preview ("Unread PRs need
          // review"). Chat hides the label once the conversation is read.
          function hasUnreadLabel(row) {
            var w = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
            for (var n = w.nextNode(); n; n = w.nextNode()) {
              if (n.nodeValue.trim() !== 'Unread') continue;
              var el = n.parentElement;
              if (el && !el.closest('[jsname=ok3btb]') && el.getClientRects().length) return true;
            }
            return false;
          }

          function conversations() {
            var map = {};
            var rows = document.querySelectorAll('[role=listitem][data-group-id][data-display-timestamp]');
            for (var i = 0; i < rows.length; i++) {
              var r = rows[i], id = r.getAttribute('data-group-id');
              var ts = parseInt(r.getAttribute('data-display-timestamp'), 10) || 0;
              // Milliseconds since the epoch (observed: 1791433185952, Oct 2026);
              // tolerate microseconds should that ever change.
              if (ts > 1e14) ts = Math.floor(ts / 1000);
              var it = r.innerText || '';
              var nm = /(\d+)\s+Notifications?/.exec(it);
              var c = map[id] || (map[id] = { id: id, ts: 0, alerts: 0, name: '', text: '', unread: false });
              c.ts = Math.max(c.ts, ts);
              // Unread rows: the Home list marks them data-is-unread="true"; the
              // sidebar shows an "Unread" label, hidden once read.
              if (r.getAttribute('data-is-unread') === 'true' || hasUnreadLabel(r)) c.unread = true;
              if (nm) c.alerts = Math.max(c.alerts, parseInt(nm[1], 10));
              var preview = r.querySelector('[jsname=ok3btb]');
              if (preview && !c.text) c.text = (preview.innerText || '').trim().slice(0, 300);
              if (!c.name) c.name = nameOf(r);
            }
            return map;
          }

          function check(){
            var links = document.querySelectorAll('link[rel~="icon"]');
            var unread = false;
            for (var i = 0; i < links.length; i++) {
              var h = links[i].href;
              // Exclude "no_dot": it also contains the substring "_dot_".
              if (/_dot_/.test(h) && !/no_dot/.test(h)) { unread = true; break; }
            }
            var count = 0;
            var home = document.querySelector('[aria-label^="Home shortcut"]');
            var m = home && /(\d+)\s+unread/i.exec(home.getAttribute('aria-label'));
            if (m) count = parseInt(m[1], 10);

            // New news is a rise in a conversation's notification count -- not
            // any timestamp bump, which edits, reactions and your own messages
            // from another device also cause. A row seen for the first time (the
            // list scrolled or finished loading) is new only if its last
            // activity is after the page loaded.
            var messages = [], convs = conversations();
            for (var id in convs) {
              var c = convs[id], prev = seen[id];
              var rose = prev === undefined ? (c.ts > startedAt && c.alerts > 0)
                                            : c.alerts > (seenAlerts[id] || 0);
              if (rose) messages.push({ id: c.id, name: c.name, text: c.text, count: c.alerts });
              seen[id] = Math.max(prev || 0, c.ts);
              seenAlerts[id] = c.alerts;
            }

            // The unread conversations, newest first, for the menu-bar inbox.
            var inbox = [];
            for (var k in convs) if (convs[k].unread) inbox.push(convs[k]);
            inbox.sort(function(a, b){ return b.ts - a.ts; });
            inbox = inbox.slice(0, 20).map(function(c){
              return { id: c.id, name: c.name, text: c.text, count: c.alerts };
            });

            // Any change to what the inbox shows (a name that loads late, a new
            // preview of the same length) is reported.
            var key = unread + ':' + count + ':' + JSON.stringify(inbox);
            // Which of the selectors this relies on currently match, so the app
            // can log when Chat's markup changes under it.
            // (Not in the first 30 s: the sidebar is empty while Chat loads.)
            var health = Date.now() - startedAt < 30000 ? null :
              { rows: document.querySelectorAll('[role=listitem][data-group-id][data-display-timestamp]').length,
                home: !!home };
            if (health) key += ':' + (health.rows > 0) + ':' + health.home;
            if (key !== last || messages.length) {
              last = key;
              window.webkit.messageHandlers.badge.postMessage(
                { unread: unread, count: count, messages: messages, inbox: inbox, health: health });
            }
          }
          window.__chatsUnreadReset = function(){ last = null; check(); };
          setInterval(check, 2000);
          check();
        })();
        """#
        cfg.userContentController.addUserScript(
            WKUserScript(source: unreadProbe, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.add(self, name: "badge")

        // WKWebView gives pages no working Notification API. Install a stand-in
        // at document start that reports permission "granted" and forwards any
        // page-level notification to Notification Center; a banner click calls
        // back into the page (__chatNotifClick). Chat itself delivers message
        // alerts via Web Push to its service worker, which WKWebView does not
        // support, so in practice new-message banners come from the unread
        // signal instead (see notifyUnread); this covers anything Chat does show
        // from the page. All frames: Chat runs parts of its UI in iframes.
        let notifyShim = """
        (function(){
          if (window.__chatNotifShim) return;
          window.__chatNotifShim = true;
          var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.notify;
          if (!mh) return;
          var seq = 0, live = {}, order = [];
          function Shim(title, opts) {
            opts = opts || {};
            this.title = String(title == null ? '' : title);
            this.body = opts.body == null ? '' : String(opts.body);
            this.tag = opts.tag == null ? '' : String(opts.tag);
            this.data = opts.data;
            this.icon = opts.icon;
            this.onclick = this.onclose = this.onshow = this.onerror = null;
            this._l = {};
            this._id = Date.now() + '-' + (++seq);
            live[this._id] = this;
            order.push(this._id);
            if (order.length > 200) delete live[order.shift()];
            mh.postMessage({ type: 'show', id: this._id, title: this.title, body: this.body, tag: this.tag });
            var self = this;
            setTimeout(function(){ self._fire('show'); }, 0);
          }
          Shim.prototype.addEventListener = function(t, f){ (this._l[t] = this._l[t] || []).push(f); };
          Shim.prototype.removeEventListener = function(t, f){
            var a = this._l[t]; if (a) { var i = a.indexOf(f); if (i >= 0) a.splice(i, 1); }
          };
          Shim.prototype._fire = function(t){
            var ev = { type: t, target: this, currentTarget: this, preventDefault: function(){} };
            var h = this['on' + t];
            if (typeof h === 'function') { try { h.call(this, ev); } catch (e) {} }
            (this._l[t] || []).slice().forEach(function(f){ try { f.call(this, ev); } catch (e) {} }, this);
          };
          Shim.prototype.close = function(){
            if (!live[this._id]) return;
            delete live[this._id];
            mh.postMessage({ type: 'close', id: this._id });
            this._fire('close');
          };
          Shim.permission = 'granted';
          Shim.maxActions = 0;
          Shim.requestPermission = function(cb){
            if (typeof cb === 'function') cb('granted');
            return Promise.resolve('granted');
          };
          window.__chatNotifClick = function(id){
            var n = live[id];
            if (n) { try { window.focus(); } catch (e) {} n._fire('click'); }
          };
          Object.defineProperty(window, 'Notification', { value: Shim, writable: true, configurable: true });
          if (window.ServiceWorkerRegistration) {
            ServiceWorkerRegistration.prototype.showNotification = function(title, opts){
              new Shim(title, opts); return Promise.resolve();
            };
          }
          if (navigator.permissions && navigator.permissions.query) {
            var q = navigator.permissions.query.bind(navigator.permissions);
            navigator.permissions.query = function(d){
              if (d && d.name === 'notifications') {
                return Promise.resolve({ state: 'granted', status: 'granted', onchange: null,
                  addEventListener: function(){}, removeEventListener: function(){} });
              }
              return q(d);
            };
          }
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: notifyShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(self, name: "notify")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        // Present as Safari so Google's login does not flag an "insecure browser".
        wv.customUserAgent = safariUA
        wv.uiDelegate = self
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        // Settings > Advanced: Safari > Develop > Chats lists each page.
        wv.isInspectable = UserDefaults.standard.bool(forKey: "WebInspector")
        return wv
    }

    // MARK: - Workspace rail

    func buildRail(in root: NSView, width: CGFloat, height: CGFloat) {
        let rail = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        rail.autoresizingMask = [.height]
        rail.wantsLayer = true
        root.addSubview(rail)
        railView = rail

        let flip = FlippedView(frame: rail.bounds)
        flip.autoresizingMask = [.width, .height]
        rail.addSubview(flip)
        railContent = flip

        let side: CGFloat = 44
        for ws in workspaces {
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
            btn.isBordered = false
            btn.bezelStyle = .regularSquare
            btn.imageScaling = .scaleProportionallyUpOrDown
            btn.image = workspaceImage(ws)
            btn.imagePosition = .imageOnly
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 10
            btn.layer?.masksToBounds = true
            btn.toolTip = ws.name
            btn.target = self
            btn.action = #selector(railClicked(_:))
            btn.menu = railMenu(for: ws)   // right-click / ctrl-click
            flip.addSubview(btn)
            ws.button = btn

            let dot = NSView(frame: .zero)
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.borderWidth = 2
            dot.isHidden = true
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            dot.addSubview(label)
            flip.addSubview(dot)   // above the button, in the rail
            ws.dot = dot
            ws.dotLabel = label
        }
        layoutRail()
    }

    // Stack the rail buttons top-down in the current workspace order.
    func layoutRail() {
        guard let flip = railContent else { return }
        let side: CGFloat = 44
        var y: CGFloat = 12
        for ws in workspaces {
            ws.button?.frame = NSRect(x: (flip.bounds.width - side) / 2, y: y, width: side, height: side)
            updateRailBadge(ws)
            y += side + 12
        }
    }

    // Right-click menu on a rail button.
    func railMenu(for ws: Workspace) -> NSMenu {
        let menu = NSMenu()
        func items(_ list: [(String, Selector?)], into menu: NSMenu, tag: Int = 0) {
            for (title, action) in list {
                guard let action = action else { menu.addItem(NSMenuItem.separator()); continue }
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = ws
            }
        }
        let notifMenu = NSMenu()
        items([("Mute for 1 Hour", #selector(muteHour(_:))),
               ("Mute Until Tomorrow", #selector(muteTomorrow(_:))),
               ("Mute", #selector(muteIndefinitely(_:))),
               ("Unmute", #selector(unmute(_:))),
               ("", nil),
               ("Quiet Hours", #selector(toggleQuietHours(_:)))], into: notifMenu)
        menu.addItem(withTitle: "Notifications", action: nil, keyEquivalent: "").submenu = notifMenu
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLaunchAtLogin(_:)):
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return true
        case #selector(toggleMenuBarIcon(_:)):
            item.state = statusItem != nil ? .on : .off
            return true
        case #selector(setAppAppearance(_:)):
            item.state = UserDefaults.standard.integer(forKey: "AppAppearance") == item.tag ? .on : .off
            return true
        default: break
        }
        guard let ws = item.representedObject as? Workspace else { return true }
        let d = UserDefaults.standard
        switch item.action {
        case #selector(unmute(_:)):
            return (d.object(forKey: "MuteUntil.\(ws.key)") as? Date).map { $0 > Date() } ?? false
        case #selector(muteIndefinitely(_:)):
            item.state = (d.object(forKey: "MuteUntil.\(ws.key)") as? Date) == .distantFuture ? .on : .off
            return true
        case #selector(toggleQuietHours(_:)):
            item.state = d.bool(forKey: "QuietHours.\(ws.key)") ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: - Appearance

    // View > Appearance: System / Light / Dark for the app itself -- window,
    // title bar, rail, menus. Chat has its own theme setting, so its pages keep
    // following the system appearance whatever is chosen here.
    @objc func setAppAppearance(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "AppAppearance")
        applyAppearance()
    }

    var systemIsDark: Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

    func applyAppearance() {
        defer { refreshSettings() }
        let choice = UserDefaults.standard.integer(forKey: "AppAppearance")   // 0 system, 1 light, 2 dark
        NSApp.appearance = choice == 1 ? NSAppearance(named: .aqua)
            : choice == 2 ? NSAppearance(named: .darkAqua) : nil
        let dark = choice == 2 || (choice == 0 && systemIsDark)
        let system = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        for ws in workspaces { ws.webView.appearance = system; ws.watcher?.appearance = system }
        for win in popupWindows { win.contentView?.appearance = system }
        let rail = NSColor(calibratedWhite: dark ? 0.12 : 0.88, alpha: 1).cgColor
        railView?.layer?.backgroundColor = rail
        for ws in workspaces { ws.dot?.layer?.borderColor = rail }
    }

    // MARK: - Mute and quiet hours

    func setMute(_ sender: NSMenuItem, until date: Date?) {
        guard let ws = sender.representedObject as? Workspace else { return }
        UserDefaults.standard.set(date, forKey: "MuteUntil.\(ws.key)")
        updateBadges()
    }

    @objc func muteHour(_ sender: NSMenuItem) { setMute(sender, until: Date().addingTimeInterval(3600)) }
    @objc func muteIndefinitely(_ sender: NSMenuItem) { setMute(sender, until: .distantFuture) }
    @objc func unmute(_ sender: NSMenuItem) { setMute(sender, until: nil) }
    // Until 08:00 tomorrow -- a fixed morning, not the quiet-hours end (with a
    // 09:00-17:00 range that would be 17:00 tomorrow).
    @objc func muteTomorrow(_ sender: NSMenuItem) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        setMute(sender, until: cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow))
    }

    @objc func toggleQuietHours(_ sender: NSMenuItem) {
        guard let ws = sender.representedObject as? Workspace else { return }
        let key = "QuietHours.\(ws.key)"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        updateBadges()
        refreshSettings()
    }

    // Quiet hours: weekday hours from `start` to `end` (either a same-day
    // range or one that wraps past midnight), plus all weekend unless turned
    // off. Defaults 18:00-08:00 and weekends; all set in Settings.
    var quietHours: (start: Int, end: Int) {
        let d = UserDefaults.standard
        return (d.object(forKey: "QuietHoursStart") as? Int ?? 18, d.object(forKey: "QuietHoursEnd") as? Int ?? 8)
    }

    var quietWeekends: Bool { UserDefaults.standard.object(forKey: "QuietHoursWeekends") as? Bool ?? true }

    // Banners and Dock bounces are skipped while muted; badges still update.
    func isMuted(_ ws: Workspace, at now: Date = Date()) -> Bool {
        let d = UserDefaults.standard
        if let until = d.object(forKey: "MuteUntil.\(ws.key)") as? Date, until > now { return true }
        guard d.bool(forKey: "QuietHours.\(ws.key)") else { return false }
        let cal = Calendar.current
        if quietWeekends && cal.isDateInWeekend(now) { return true }
        let (start, end) = quietHours
        let hour = cal.component(.hour, from: now)
        // 09:00-17:00 is a same-day range; 18:00-08:00 wraps past midnight;
        // start == end is an empty range (weekdays never quiet).
        if start == end { return false }
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    // Rail badge: hidden, a small dot (unread, no count), or a red pill with
    // the count, pinned to the button's top-right corner.
    func updateRailBadge(_ ws: Workspace) {
        guard let dot = ws.dot, let label = ws.dotLabel, let btn = ws.button else { return }
        let show = ws.unread || ws.unreadCount > 0
        dot.isHidden = !show
        guard show else { return }
        dot.layer?.backgroundColor = (isMuted(ws) ? NSColor.systemGray : NSColor.systemRed).cgColor
        if ws.unreadCount > 0 {
            label.stringValue = ws.unreadCount > 99 ? "99+" : String(ws.unreadCount)
            let h: CGFloat = 18
            let w = max(h, ceil(label.intrinsicContentSize.width) + 10)
            dot.frame = NSRect(x: btn.frame.maxX - w + 6, y: btn.frame.minY - 4, width: w, height: h)
            label.frame = NSRect(x: 0, y: (h - label.intrinsicContentSize.height) / 2,
                                 width: w, height: label.intrinsicContentSize.height)
            label.isHidden = false
            dot.layer?.cornerRadius = h / 2
        } else {
            let d: CGFloat = 12
            dot.frame = NSRect(x: btn.frame.maxX - d + 2, y: btn.frame.minY - 2, width: d, height: d)
            label.isHidden = true
            dot.layer?.cornerRadius = d / 2
        }
    }

    func workspaceImage(_ ws: Workspace) -> NSImage? {
        var logo: NSImage?
        if let f = ws.iconFile {
            let base = (f as NSString).deletingPathExtension
            let ext = (f as NSString).pathExtension
            if let path = Bundle.main.path(forResource: base, ofType: ext) {
                logo = NSImage(contentsOfFile: path)
            }
        }
        // Logos are transparent and often dark, so they vanish on the dark rail.
        // Draw each on a light rounded tile, inset so the selection highlight on
        // the button still shows around it. No logo -> the name's first letter.
        let side: CGFloat = 44, inset: CGFloat = 4, pad: CGFloat = 4
        let initial = String(ws.name.prefix(1)).uppercased()
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let tile = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).fill()
            let box = tile.insetBy(dx: pad, dy: pad)
            if let logo = logo, logo.size.width > 0, logo.size.height > 0 {
                let s = min(box.width / logo.size.width, box.height / logo.size.height)
                let w = logo.size.width * s, h = logo.size.height * s
                logo.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                    .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1),
                ]
                let str = NSAttributedString(string: initial, attributes: attrs)
                let sz = str.size()
                str.draw(at: NSPoint(x: tile.midX - sz.width / 2, y: tile.midY - sz.height / 2))
            }
            return true
        }
    }

    @objc func railClicked(_ sender: NSButton) {
        if let ws = workspaces.first(where: { $0.button === sender }) { select(ws) }
    }

    func select(_ ws: Workspace) {
        for w in workspaces {
            w.webView.isHidden = (w !== ws)
            w.button?.layer?.backgroundColor = (w === ws)
                ? NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
                : NSColor.clear.cgColor
        }
        current = ws
        window.title = workspaces.count > 1
            ? "\((Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Chat") -- \(ws.name)"
            : ws.name
        window.makeFirstResponder(ws.webView)
    }

    // MARK: - Reload

    // A reload starts the unread probe from scratch; treat its first report as
    // the baseline again so a reload never raises a banner for old unread.
    func reload(_ ws: Workspace, watcherToo: Bool = true) {
        ws.unreadReported = false
        ws.webView.reload()
        guard watcherToo else { return }
        ws.watcherReported = false
        ws.watcher?.reload()
    }

    // MARK: - Window, launch at login, menu bar

    func showWindow(_ ws: Workspace? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let ws = ws { select(ws) }
    }

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            // Registered (also while awaiting approval in System Settings): turn off.
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "You can add Chats in System Settings > General > Login Items."
            alert.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refreshSettings()
    }

    @objc func toggleMenuBarIcon(_ sender: Any?) {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        } else {
            installStatusItem()
        }
        UserDefaults.standard.set(statusItem != nil, forKey: "ShowMenuBarIcon")
        refreshSettings()
    }

    func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = NSMenu()
        statusItem?.menu?.delegate = self
        updateBadges()
    }

    // One line per workspace with its unread count; used by the menu-bar icon
    // and the Dock icon's right-click menu.
    func workspaceMenu(into menu: NSMenu) {
        for ws in workspaces {
            var title = ws.name
            let n = ws.unread ? max(ws.unreadCount, 1) : ws.unreadCount
            if n > 0 { title += " (\(n))" }
            if isMuted(ws) { title += " \u{2014} muted" }
            let item = menu.addItem(withTitle: title, action: #selector(openWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws
        }
    }

    @objc func openWorkspace(_ sender: NSMenuItem) {
        showWindow(sender.representedObject as? Workspace)
    }

    // Dock right-click: each workspace, then its unread conversations. The Dock
    // draws menus itself as plain text, so each is one line: "Name -- preview".
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let workspaceItems = NSMenu()
        workspaceMenu(into: workspaceItems)
        for ws in workspaces {
            if let item = workspaceItems.items.first(where: { $0.representedObject as? Workspace === ws }) {
                workspaceItems.removeItem(item)
                menu.addItem(item)
            }
            for c in ws.inbox {
                var title = "      " + (c.name.isEmpty ? "Conversation" : c.name)
                let preview = c.text.replacingOccurrences(of: "\n", with: " ")
                if !preview.isEmpty {
                    title += " \u{2014} " + (preview.count > 40 ? String(preview.prefix(37)) + "\u{2026}" : preview)
                }
                let item = menu.addItem(withTitle: title, action: #selector(openInboxItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = InboxRef(ws: ws, conv: c.id)
            }
        }
        return menu
    }

    // Dock badge, menu-bar icon and rail badges from the current unread state.
    func updateBadges() {
        workspaces.forEach(updateRailBadge)
        let total = workspaces.reduce(0) { $0 + ($1.unread ? max($1.unreadCount, 1) : $1.unreadCount) }
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
        if let button = statusItem?.button {
            let symbol = total > 0 ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Chats")
            button.image?.isTemplate = true
            button.title = total > 0 ? " \(total)" : ""
            button.imagePosition = .imageLeading
        }
    }

    // MARK: - Sleep, network and crash recovery

    // After sleep or a network drop the page can look connected while its
    // real-time channel is dead, so new messages (and banners) silently stop.
    // Reload every workspace after a sleep or outage of more than a minute.
    func watchSleepAndNetwork() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleepSince = Date()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let since = self.asleepSince else { return }
            self.asleepSince = nil
            if Date().timeIntervalSince(since) > 60 { self.reloadAllWhenOnline() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if path.status != .satisfied {
                    if self.offlineSince == nil { self.offlineSince = Date() }
                } else if let since = self.offlineSince {
                    self.offlineSince = nil
                    // Also redo a reload that ran during this outage: it loaded
                    // nothing.
                    let reloadedOffline = (self.lastFullReload ?? .distantPast) >= since
                    if Date().timeIntervalSince(since) > 60 || self.reloadWhenOnline || reloadedOffline {
                        self.reloadWhenOnline = false
                        self.reloadAllWhenOnline(force: reloadedOffline)
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "chats.network"))
        pathMonitor = monitor
    }

    // Wait out the first seconds after wake, when Wi-Fi is still joining. Wake
    // and reconnect often both fire: one reload a minute is enough, unless
    // `force` (the previous one ran while offline).
    func reloadAllWhenOnline(force: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if self.offlineSince != nil { self.reloadWhenOnline = true; return }
            if !force, let last = self.lastFullReload, Date().timeIntervalSince(last) < 60 { return }
            self.lastFullReload = Date()
            self.workspaces.forEach { self.reload($0) }
        }
    }

    // WebKit killed the page's process (memory pressure, crash): reload it
    // rather than leave a blank workspace. A page that keeps crashing
    // (typically macOS killing it under memory pressure) is reloaded with
    // backoff -- at once, then after 10 s, then 60 s -- and after 3 crashes in
    // 10 minutes left alone until the next wake or reconnect.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Also for the hidden Home view (Settings > Message previews).
        let isWatcher = workspaces.contains { $0.watcher === webView }
        guard let ws = workspaces.first(where: { $0.webView === webView || $0.watcher === webView }) else { return }
        ws.crashes = ws.crashes.filter { Date().timeIntervalSince($0) < 600 } + [Date()]
        let delays: [Double] = [0, 10, 60]
        guard ws.crashes.count <= delays.count else {
            chatLog.error("\(ws.name, privacy: .public): page crashed \(ws.crashes.count) times in 10 minutes; not reloading")
            return
        }
        let delay = delays[ws.crashes.count - 1]
        chatLog.warning("\(ws.name, privacy: .public): page crashed; reloading in \(Int(delay), privacy: .public) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            if isWatcher {
                ws.watcherReported = false
                webView.reload()
            } else {
                self?.reload(ws, watcherToo: false)
            }
        }
    }

    // MARK: - Message previews

    // Banner previews come from Chat's Home list, which is only on the page
    // while a workspace shows Home; the sidebar (always there) has names and
    // counts but no text. Settings > Message previews picks how to cope:
    //   0  only while a workspace is on Home (default)
    //   1  reload a workspace to Home once it has been off screen for N minutes
    //   2  keep a hidden second web view per workspace that stays on Home
    var previewMode: Int { UserDefaults.standard.integer(forKey: "PreviewMode") }
    var returnHomeMinutes: Int { UserDefaults.standard.object(forKey: "ReturnHomeMinutes") as? Int ?? 5 }

    func applyPreviewMode() {
        for ws in workspaces {
            if previewMode == 2, ws.watcher == nil {
                // Same data store (same sign-in), same scripts and delegates;
                // kept hidden at the bottom of the window's view stack.
                let wv = makeWebView(for: ws)
                wv.frame = container.bounds
                wv.autoresizingMask = [.width, .height]
                wv.isHidden = true
                container.addSubview(wv, positioned: .below, relativeTo: nil)
                wv.appearance = ws.webView.appearance
                ws.watcher = wv
                ws.watcherReported = false
                wv.load(URLRequest(url: ws.url))
            } else if previewMode != 2, let wv = ws.watcher {
                wv.removeFromSuperview()
                ws.watcher = nil
                // Its inbox and counts are stale now; have the visible view
                // report afresh (it otherwise only reports changes).
                ws.inbox = []
                ws.unreadReported = false
                ws.webView.evaluateJavaScript("window.__chatsUnreadReset && window.__chatsUnreadReset()")
                updateBadges()
            }
        }
    }

    // Mode 1: a workspace that has been off screen for N minutes and is not on
    // Home is reloaded to Home. "On screen" means it is the workspace shown in
    // a window that is actually visible -- whether or not Chats is the active
    // app, so one you are reading on a second monitor is never reloaded. A full
    // load, not a click: Chat's in-page router may not act while hidden.
    func sendBackgroundWorkspacesHome() {
        let windowOnScreen = window.isVisible && window.occlusionState.contains(.visible)
        for ws in workspaces {
            // Only time spent off screen while this mode is on counts, so
            // switching into it does not reload long-hidden workspaces at once.
            if previewMode != 1 || (ws === current && windowOnScreen) {
                ws.backgroundSince = nil
                continue
            }
            let since = ws.backgroundSince ?? Date()
            ws.backgroundSince = since
            guard Date().timeIntervalSince(since) >= Double(returnHomeMinutes) * 60,
                  let pageURL = ws.webView.url, pageURL.path != "/", !pageURL.path.hasSuffix("/app/home")
            else { continue }
            // Never while the page is elsewhere (a sign-in on accounts.google.com,
            // say) or in a call -- in the workspace itself or a popup it opened:
            // a reload would discard it.
            let inCall = ([ws.webView] + popupWebViews(of: ws)).contains {
                $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none
            }
            guard pageURL.host?.lowercased() == ws.host, !inCall else { continue }
            ws.webView.requestMediaPlaybackState { [weak self] state in
                // Audio playing (e.g. listening in a huddle with the mic off).
                guard state != .playing, self?.previewMode == 1 else { return }
                ws.backgroundSince = nil
                ws.unreadReported = false
                ws.webView.load(URLRequest(url: ws.url))
            }
        }
    }

    // Popup windows (image viewer, calls) opened from a workspace: they share
    // its data store.
    func popupWebViews(of ws: Workspace) -> [WKWebView] {
        popupWindows.compactMap { $0.contentView as? WKWebView }
            .filter { $0.configuration.websiteDataStore === ws.webView.configuration.websiteDataStore }
    }

    // MARK: - Settings window

    var settingsWindow: NSWindow?
    var settingsControls: [String: NSControl] = [:]
    var previewHelp: NSTextField?

    static let previewHelpText = [
        "Previews appear while that workspace is on Chat's Home view. Otherwise banners show the sender and \u{201C}New message\u{201D}.",
        "A workspace that has been off screen for a while reloads to Home, so previews keep coming -- never the one you can see, even with another app in front. Switching back to it lands you on Home instead of the conversation you left.",
        "Each workspace keeps an invisible copy of Chat on Home, used only for previews; your view stays where you left it. Uses more memory -- about one more Chat page per workspace.",
    ]

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { buildSettingsWindow() }
        refreshSettings()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildSettingsWindow() {
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            return l
        }
        func note(_ text: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 340
            return l
        }
        func popup(_ key: String, _ titles: [String], tags: [Int]? = nil, _ action: Selector) -> NSPopUpButton {
            let p = NSPopUpButton()
            for (i, t) in titles.enumerated() {
                p.addItem(withTitle: t)
                p.lastItem?.tag = tags?[i] ?? i
            }
            p.target = self
            p.action = action
            settingsControls[key] = p
            return p
        }
        func check(_ key: String, _ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: self, action: action)
            settingsControls[key] = b
            return b
        }
        let hours = (0..<24).map { String(format: "%02d:00", $0) }
        let help = note("")
        previewHelp = help
        let quiet = NSStackView(views: [
            popup("quietStart", hours, #selector(settingsQuietChanged(_:))),
            NSTextField(labelWithString: "to"),
            popup("quietEnd", hours, #selector(settingsQuietChanged(_:))),
        ])
        // One on/off box per workspace; all off disables quiet hours.
        let quietOn = NSStackView(views: workspaces.map { ws -> NSView in
            let b = NSButton(checkboxWithTitle: ws.name, target: self, action: #selector(settingsQuietWorkspaceChanged(_:)))
            settingsControls["quiet.\(ws.key)"] = b
            return b
        })
        quietOn.spacing = 16
        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [label("Appearance:"), popup("appearance", ["System", "Light", "Dark"], #selector(settingsAppearanceChanged(_:)))],
            [empty, check("menuBar", "Show unread inbox in the menu bar", #selector(toggleMenuBarIcon(_:)))],
            [empty, check("login", "Launch Chats at login", #selector(toggleLaunchAtLogin(_:)))],
            [label("Notifications:"), check("banners", "Show a banner for new messages",
                                            #selector(settingsBannersChanged(_:)))],
            [empty, check("bannerSound", "Play a sound with banners", #selector(settingsBannersChanged(_:)))],
            [empty, note("Chat's own notification chime is separate: if you hear two sounds, turn one off here or in Chat's settings (gear icon).")],
            [label("Message previews:"), popup("preview", ["Only while a workspace is on Home",
                                                           "Send background workspaces back to Home",
                                                           "Keep a hidden Home view per workspace"],
                                               #selector(settingsPreviewChanged(_:)))],
            [empty, help],
            [label("Back to Home after:"), popup("minutes", [1, 2, 5, 10, 15, 30].map { "\($0) minutes" },
                                                 tags: [1, 2, 5, 10, 15, 30], #selector(settingsPreviewChanged(_:)))],
            [empty, note("Skipped while a workspace is in a call or signing in.")],
            [label("Replies:"), check("replySends", "Send immediately when replying from a notification",
                                      #selector(settingsReplyChanged(_:)))],
            [empty, note("Off: your reply is typed into the conversation for you to check and send.")],
            [label("Quiet hours for:"), quietOn],
            [label("From:"), quiet],
            [empty, check("quietWeekends", "Also all weekend", #selector(settingsQuietWeekendsChanged(_:)))],
            [empty, note("No banners in these hours, for the workspaces ticked above. A range like 09:00 to 17:00 is that day; 18:00 to 08:00 runs overnight. Untick all workspaces to turn quiet hours off.")],
            [label("Advanced:"), check("inspector", "Enable Web Inspector (Safari \u{203A} Develop)",
                                       #selector(settingsInspectorChanged(_:)))],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        for key in ["banners", "preview", "replySends", "quiet.\(workspaces.first?.key ?? "")", "inspector"] {
            if let v = settingsControls[key] { grid.cell(for: v)?.row?.topPadding = 14 }
        }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        let win = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.contentView = content
        win.isReleasedWhenClosed = false
        win.center()
        settingsWindow = win
    }

    // Load every control from the current settings (they can also change from
    // the menus).
    func refreshSettings() {
        let d = UserDefaults.standard
        (settingsControls["appearance"] as? NSPopUpButton)?.selectItem(withTag: d.integer(forKey: "AppAppearance"))
        (settingsControls["menuBar"] as? NSButton)?.state = statusItem != nil ? .on : .off
        (settingsControls["login"] as? NSButton)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        (settingsControls["preview"] as? NSPopUpButton)?.selectItem(withTag: previewMode)
        (settingsControls["minutes"] as? NSPopUpButton)?.selectItem(withTag: returnHomeMinutes)
        settingsControls["minutes"]?.isEnabled = previewMode == 1
        (settingsControls["quietStart"] as? NSPopUpButton)?.selectItem(withTag: quietHours.start)
        (settingsControls["quietEnd"] as? NSPopUpButton)?.selectItem(withTag: quietHours.end)
        let anyQuiet = workspaces.contains { d.bool(forKey: "QuietHours.\($0.key)") }
        for ws in workspaces {
            (settingsControls["quiet.\(ws.key)"] as? NSButton)?.state = d.bool(forKey: "QuietHours.\(ws.key)") ? .on : .off
        }
        settingsControls["quietStart"]?.isEnabled = anyQuiet
        settingsControls["quietEnd"]?.isEnabled = anyQuiet
        settingsControls["quietWeekends"]?.isEnabled = anyQuiet
        (settingsControls["quietWeekends"] as? NSButton)?.state = quietWeekends ? .on : .off
        (settingsControls["replySends"] as? NSButton)?.state = replySendsImmediately ? .on : .off
        (settingsControls["banners"] as? NSButton)?.state = bannersEnabled ? .on : .off
        (settingsControls["bannerSound"] as? NSButton)?.state = bannerSound ? .on : .off
        settingsControls["bannerSound"]?.isEnabled = bannersEnabled
        (settingsControls["inspector"] as? NSButton)?.state = d.bool(forKey: "WebInspector") ? .on : .off
        previewHelp?.stringValue = Self.previewHelpText[min(previewMode, 2)]
        if let win = settingsWindow, let content = win.contentView {
            win.setContentSize(content.fittingSize)
        }
    }

    @objc func settingsAppearanceChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.selectedTag(), forKey: "AppAppearance")
        applyAppearance()
    }

    @objc func settingsPreviewChanged(_ sender: NSPopUpButton) {
        let d = UserDefaults.standard
        if let p = settingsControls["preview"] as? NSPopUpButton { d.set(p.selectedTag(), forKey: "PreviewMode") }
        if let m = settingsControls["minutes"] as? NSPopUpButton { d.set(m.selectedTag(), forKey: "ReturnHomeMinutes") }
        applyPreviewMode()
        refreshSettings()
    }

    @objc func settingsQuietWeekendsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "QuietHoursWeekends")
        updateBadges()
    }

    @objc func settingsBannersChanged(_ sender: NSButton) {
        let d = UserDefaults.standard
        if let b = settingsControls["banners"] as? NSButton { d.set(b.state == .on, forKey: "BannersEnabled") }
        if let b = settingsControls["bannerSound"] as? NSButton { d.set(b.state == .on, forKey: "BannerSound") }
        refreshSettings()
    }

    @objc func settingsReplyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "ReplySendsImmediately")
        registerNotificationCategories()
    }

    @objc func settingsInspectorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "WebInspector")
        for ws in workspaces {
            ws.webView.isInspectable = sender.state == .on
            ws.watcher?.isInspectable = sender.state == .on
        }
    }

    @objc func settingsQuietWorkspaceChanged(_ sender: NSButton) {
        guard let ws = workspaces.first(where: { settingsControls["quiet.\($0.key)"] === sender }) else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: "QuietHours.\(ws.key)")
        refreshSettings()
        updateBadges()
    }

    @objc func settingsQuietChanged(_ sender: NSPopUpButton) {
        let d = UserDefaults.standard
        if let p = settingsControls["quietStart"] as? NSPopUpButton { d.set(p.selectedTag(), forKey: "QuietHoursStart") }
        if let p = settingsControls["quietEnd"] as? NSPopUpButton { d.set(p.selectedTag(), forKey: "QuietHoursEnd") }
        updateBadges()
    }

    // MARK: - Side-panel companions (Calendar)

    // Chat's side panel embeds Calendar from calendar.google.com. Calendar keeps
    // its own per-service sign-in cookie; with none in a workspace's fresh,
    // isolated store, the embedded page bounces through
    // accounts.google.com/ServiceLogin, whose return trip to calendar.google.com
    // inside Chat's iframe is blocked by Chat's CSP (frame-src) -- and the panel
    // shows "Couldn't load". A browser never hits this because Calendar was
    // opened directly at some point. So open Calendar once, top-level and
    // hidden, in the same store: it signs itself in there, outside Chat's CSP,
    // and the panel then loads directly. Redone whenever the panel is seen
    // bouncing to sign-in again (cookie expired).
    // `retryPanel`: the panel already failed; once signed in, reload its iframe
    // so it recovers without the user pressing "Try again".
    func warmUpCompanion(_ ws: Workspace, host: String, retryPanel: Bool = false) {
        let key = "\(ws.key)|\(host)"
        // Already warming up (e.g. the startup one): reload the panel when done.
        if warmUps[key] != nil {
            if retryPanel { panelRetryPending.insert(key) }
            return
        }
        guard let url = URL(string: "https://\(host)/") else { return }
        // A panel that keeps bouncing to sign-in would otherwise cycle forever
        // (reload -> bounce -> warm-up): at most 2 recoveries per 10 minutes.
        if retryPanel {
            let recent = (panelRecoveries[key] ?? []).filter { Date().timeIntervalSince($0) < 600 }
            guard recent.count < 2 else {
                chatLog.warning("\(ws.name, privacy: .public): \(host, privacy: .public) side panel still needs sign-in; not retrying for now")
                return
            }
            panelRecoveries[key] = recent + [Date()]
        }
        warmUps[key] = CompanionWarmUp(url: url, store: ws.webView.configuration.websiteDataStore,
                                       userAgent: ws.webView.customUserAgent) { [weak self] ok in
            DispatchQueue.main.async {
                self?.warmUps[key] = nil
                let pending = self?.panelRetryPending.remove(key) != nil
                guard ok, retryPanel || pending else { return }
                ws.webView.callAsyncJavaScript(#"""
                    for (const f of document.querySelectorAll('iframe')) {
                      try { if (new URL(f.src).host === host) f.src = f.src; } catch (e) {}
                    }
                    """#, arguments: ["host": host], in: nil, in: .page, completionHandler: nil)
            }
        }
    }

    // The panel's iframe being sent to sign-in for a service, e.g.
    // accounts.google.com/ServiceLogin?service=cl&continue=https://calendar.google.com/...
    func companionNeedingSignIn(_ url: URL) -> String? {
        guard url.host == "accounts.google.com", url.path.hasPrefix("/ServiceLogin"),
              let cont = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "continue" })?.value,
              let host = URL(string: cont)?.host, host.hasSuffix(".google.com"), host != "chat.google.com"
        else { return nil }
        return host
    }

    // MARK: - Camera and microphone

    // Huddles and calls inside Chat ask for the camera/mic. Grant Google's own
    // origins (macOS still asks the user once, per Info.plist's usage strings);
    // anything else gets WebKit's default prompt.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host.lowercased()
        decisionHandler(host == "google.com" || host.hasSuffix(".google.com") ? .grant : .prompt)
    }

    // MARK: - Navigation / popups

    // User clicked a link: send external links to the default browser, keep the
    // app's own + Google-login navigation in-session.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame, let url = navigationAction.request.url, let host = companionNeedingSignIn(url),
           let ws = workspaces.first(where: { $0.webView === webView }) {
            warmUpCompanion(ws, host: host, retryPanel: true)
        }
        if navigationAction.navigationType == .linkActivated, isMainFrame,
           let url = navigationAction.request.url, isExternal(url) {
            openExternally(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // New window / target=_blank / window.open. Chat opens image attachments and
    // Google sign-in this way. External links go to the default browser; image
    // attachments open in our scale-to-fit viewer window; everything else
    // (crucially, the Google sign-in flow) loads in the ORIGINATING workspace's
    // own web view, so the resulting session lands in that workspace rather than
    // a detached popup window.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.shouldPerformDownload {
            webView.startDownload(using: navigationAction.request) { [weak self] dl in
                dl.delegate = self
            }
            return nil
        }
        if let url = navigationAction.request.url {
            if isExternal(url) {
                openExternally(url)
            } else if isChatAttachment(url) {
                openImageViewer(url, source: webView, features: windowFeatures)
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    // Chat opens attachments via window.open on a chat.google.com attachment
    // endpoint that redirects to chat.usercontent.google.com.
    func isChatAttachment(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "chat.usercontent.google.com" { return true }
        if appHosts.contains(host) && url.path == "/api/get_attachment_url" { return true }
        return false
    }

    // Open an attachment in a centered, scale-to-fit viewer. The image is
    // embedded in a minimal HTML wrapper we control (dark backdrop, object-fit
    // contain) so it fills the window while preserving aspect ratio. If the
    // attachment is not an image, the <img> onerror falls back to loading the
    // raw URL directly. The popup shares the source web view's data store so the
    // attachment authorizes with the right account's cookies.
    func openImageViewer(_ url: URL, source: WKWebView, features: WKWindowFeatures) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = source.configuration.websiteDataStore
        let popup = WKWebView(frame: .zero, configuration: cfg)
        popup.customUserAgent = source.customUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        showPopupWindow(popup, features: features)

        let src = url.absoluteString.replacingOccurrences(of: "'", with: "%27")
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body { margin: 0; height: 100%; background: #202124; }
          .wrap { position: fixed; inset: 0; display: flex;
                  align-items: center; justify-content: center; }
          img { width: 100%; height: 100%; object-fit: contain; display: block; }
        </style></head>
        <body><div class="wrap">
          <img src="\(src)" onerror="location.href='\(src)'">
        </div></body></html>
        """
        popup.loadHTMLString(html, baseURL: url)
    }

    // Put a popup web view in a titled, closable window (Esc/Cmd-W close it).
    func showPopupWindow(_ popup: WKWebView, features: WKWindowFeatures) {
        popup.allowsBackForwardNavigationGestures = true
        let w = (features.width as? CGFloat) ?? 1100
        let h = (features.height as? CGFloat) ?? 820
        let win = PopupWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        win.title = window.title
        win.contentView = popup
        popup.appearance = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        popupWindows.insert(win)
    }

    // JS called window.close() on the popup -- close its window.
    func webViewDidClose(_ webView: WKWebView) {
        if let win = popupWindows.first(where: { $0.contentView === webView }) {
            win.close()
        }
    }

    // Closing the main window hides it instead, so the app keeps running and the
    // unread dots stay current. Clicking the Dock icon brings it back; Cmd+Q quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            window.orderOut(nil)
            return false
        }
        return true
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // Drop our reference once a popup window is gone so it can deallocate.
    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? PopupWindow { popupWindows.remove(win) }
    }

    // A response the web view can't render, or one the server marks as an
    // attachment (Content-Disposition: attachment), becomes a download.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           cd.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    // A non-image attachment opened in the viewer turns into a download, leaving
    // the viewer window blank -- close it.
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        if let win = popupWindows.first(where: { $0.contentView === webView }) { win.close() }
    }

    // MARK: - Downloads

    // Save to ~/Downloads under the server's filename, adding " (1)", " (2)", ...
    // instead of overwriting an existing file -- or one another download in
    // flight is already writing to.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var dest = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) || downloads.values.contains(dest) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        downloads[download] = dest
        completionHandler(dest)
    }

    // Bounce the Dock's Downloads stack, as Safari does.
    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = downloads.removeValue(forKey: download) else { return }
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: dest.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let dest = downloads.removeValue(forKey: download)
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = [dest?.lastPathComponent, error.localizedDescription]
            .compactMap { $0 }.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - File picker

    // <input type=file> (Chat's attach button). WKWebView shows no picker on
    // macOS unless the UI delegate provides one.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let host = webView.window {
            panel.beginSheetModal(for: host) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    // MARK: - JavaScript dialogs

    // alert() / confirm() / prompt(). Without these WKUIDelegate methods
    // WKWebView shows nothing: alert is dropped, confirm answers "Cancel",
    // prompt answers null.
    func jsDialog(_ webView: WKWebView, _ message: String, buttons: [String],
                  accessory: NSView? = nil, done: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "Chat"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = accessory
        if let host = webView.window, host.isVisible {
            alert.beginSheetModal(for: host, completionHandler: done)
            if let field = accessory { alert.window.initialFirstResponder = field }
        } else {
            done(alert.runModal())
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        jsDialog(webView, message, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        jsDialog(webView, message, buttons: ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        jsDialog(webView, prompt, buttons: ["OK", "Cancel"], accessory: field) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: - Unread badge

    // The injected probe reports whether a workspace has unread (favicon "dot"
    // variant) and, when Chat shows one, how many. The rail badge shows the
    // count (or a plain dot), and the Dock shows the total across workspaces.
    // A workspace with the dot but no readable count counts as 1.
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "notify" { handleNotify(message); return }
        guard message.name == "badge" else { return }
        let body = message.body as? [String: Any]
        let unread = (body?["unread"] as? Bool) ?? false
        let count = (body?["count"] as? Int) ?? 0
        let messages = (body?["messages"] as? [[String: Any]]) ?? []
        let fromWatcher = workspaces.contains { $0.watcher === message.webView }
        // With a healthy hidden Home view, it alone reports for its workspace --
        // counts, inbox and banners -- since it always has previews. The visible
        // view's reports are ignored then; if both wrote the same counts,
        // whichever came second would see no change and the fallback banner
        // could be lost. While the hidden view is unhealthy, the visible one
        // reports, so the workspace never goes silent.
        if fromWatcher, let ws = workspaces.first(where: { $0.watcher === message.webView }) {
            ws.watcherLastReport = Date()
        }
        if !fromWatcher, workspaces.contains(where: { $0.watcherHealthy && $0.webView === message.webView }) { return }
        if let ws = workspaces.first(where: { $0.webView === message.webView || $0.watcher === message.webView }) {
            ws.inbox = ((body?["inbox"] as? [[String: Any]]) ?? []).compactMap { c in
                guard let id = c["id"] as? String, !id.isEmpty else { return nil }
                return (id, (c["name"] as? String) ?? "", (c["text"] as? String) ?? "", (c["count"] as? Int) ?? 0)
            }
            checkMarkup(ws, body?["health"] as? [String: Any], page: message.webView)
            let wasUnread = ws.unread, oldCount = ws.unreadCount
            ws.unread = unread
            ws.unreadCount = count
            updateRailBadge(ws)
            // A named banner per new message when the page could tell which
            // conversation it was in; otherwise a generic one when unread starts
            // or the count goes up. Skip the first report: that is the unread
            // state at launch, not news.
            let reported = fromWatcher ? ws.watcherReported : ws.unreadReported
            for m in messages { notifyMessage(ws, m) }
            if reported && (unread != wasUnread || count > oldCount) { notifyUnread(ws) }
            if fromWatcher { ws.watcherReported = true } else { ws.unreadReported = true }
        }
        updateBadges()
    }

    // Log (once, and again on recovery) when a selector the app depends on
    // stops matching on a signed-in Chat page.
    func checkMarkup(_ ws: Workspace, _ health: [String: Any]?, page: WKWebView?) {
        guard let health = health, let url = (page ?? ws.webView).url, url.host == ws.host,
              url.path.hasPrefix("/app/") else { return }
        let checks = [("conversation rows ([role=listitem][data-group-id][data-display-timestamp])",
                       (health["rows"] as? Int ?? 0) > 0),
                      ("Home unread label ([aria-label^=\"Home shortcut\"])", health["home"] as? Bool ?? false)]
        for (name, ok) in checks {
            if !ok && !ws.markupMissing.contains(name) {
                ws.markupMissing.insert(name)
                chatLog.warning("\(ws.name, privacy: .public): Chat markup changed? no match for \(name, privacy: .public)")
            } else if ok && ws.markupMissing.remove(name) != nil {
                chatLog.notice("\(ws.name, privacy: .public): matching again: \(name, privacy: .public)")
            }
        }
    }

    // MARK: - Desktop notifications

    // Reply and Mark as Read on message banners. Reply brings the app forward
    // (Chat only opens a conversation while its page is on screen) and types
    // the reply for you to send, so its button says "Type Reply" -- or "Send"
    // when Settings has replies sent immediately.
    func registerNotificationCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [.foreground],
                                                    textInputButtonTitle: replySendsImmediately ? "Send" : "Type Reply",
                                                    textInputPlaceholder: "Reply"),
                      UNNotificationAction(identifier: "MARK_READ", title: "Mark as Read", options: [])],
            intentIdentifiers: [], options: [])])
    }

    // Runs `new Notification(...)` in the current workspace's page, exercising
    // the whole shim -> native -> Notification Center path without needing an
    // incoming Chat message. The banner shows after a short delay so you can
    // switch away first (banners are suppressed for the on-screen workspace).
    @objc func sendTestNotification(_ sender: Any?) {
        guard let ws = current else { return }
        let name = ws.name.filter { $0.isLetter || $0.isNumber || $0 == " " }
        window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            ws.webView.evaluateJavaScript(
                "new Notification('Test notification', { body: 'Chats can show notifications for \(name).' })")
        }
    }

    // Post a page notification (from the notifyShim) to Notification Center. The
    // request id carries the workspace index + page notification id so a click
    // can route back; a page "tag" makes later notifications replace earlier
    // ones, as in a browser.
    func handleNotify(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let id = body["id"] as? String,
              let ws = workspaces.first(where: { $0.webView === message.webView }) else { return }
        let center = UNUserNotificationCenter.current()

        if type == "close" {
            notifFrames.removeValue(forKey: id)
            center.getDeliveredNotifications { delivered in
                let ids = delivered.filter { ($0.request.content.userInfo["pageID"] as? String) == id }
                    .map { $0.request.identifier }
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            return
        }
        guard type == "show", bannersEnabled, !isMuted(ws) else { return }

        notifFrames[id] = message.frameInfo
        ws.lastPageNotification = Date()
        if notifFrames.count > 200, let oldest = notifFrames.keys.min() {
            notifFrames.removeValue(forKey: oldest)   // ids start with a ms timestamp
        }

        let content = UNMutableNotificationContent()
        content.title = (body["title"] as? String) ?? ""
        content.body = (body["body"] as? String) ?? ""
        if workspaces.count > 1 { content.subtitle = ws.name }
        content.sound = bannerSound ? .default : nil
        content.threadIdentifier = ws.name
        content.userInfo = ["workspace": ws.key, "pageID": id]
        let tag = (body["tag"] as? String) ?? ""
        let reqID = tag.isEmpty ? "\(ws.key)|\(id)" : "\(ws.key)|tag|\(tag)"
        center.add(UNNotificationRequest(identifier: reqID, content: content, trigger: nil))
        bounceDock()
    }

    // One Dock bounce for a new message while the app is in the background
    // (the same as Slack's default; .criticalRequest would bounce until opened).
    func bounceDock() {
        if bannersEnabled && !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // Settings > Notifications. Off: no banners, sounds or Dock bounces (unread
    // counts, badges and the inbox still update). The sound can be turned off
    // on its own -- e.g. when Chat's own in-page chime is left on.
    var bannersEnabled: Bool { UserDefaults.standard.object(forKey: "BannersEnabled") as? Bool ?? true }
    var bannerSound: Bool { UserDefaults.standard.object(forKey: "BannerSound") as? Bool ?? true }

    func workspace(forKey key: Any?) -> Workspace? {
        guard let key = key as? String else { return nil }
        return workspaces.first { $0.key == key }
    }

    // Post a banner with a fresh request id under a group prefix (one
    // conversation, or a workspace's generic "unread" banner) so the group can
    // be withdrawn together once read. Every post is its own banner: re-adding
    // an id still in Notification Center would only update it in place -- no
    // banner, no sound.
    func postBanner(_ content: UNNotificationContent, group: String) {
        guard bannersEnabled else { return }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: group + "#" + UUID().uuidString, content: content, trigger: nil))
    }

    // A new message in a known conversation: banner titled with the
    // conversation (the sender, for a DM) and, when Chat's Home list shows it,
    // the message preview. Every message gets its own banner; clicking one
    // opens that conversation.
    func notifyMessage(_ ws: Workspace, _ m: [String: Any]) {
        guard let conv = m["id"] as? String, !conv.isEmpty else { return }
        let name = (m["name"] as? String) ?? ""
        let text = (m["text"] as? String) ?? ""
        let count = (m["count"] as? Int) ?? 0
        // The same report twice (e.g. the sidebar and Home rows of one
        // conversation) within 15 s is one banner; a different text or count
        // -- a new message, even without a preview -- is another.
        if let last = ws.lastBanner[conv], last.text == text, last.count == count,
           Date().timeIntervalSince(last.at) < 15 { return }
        ws.lastBanner[conv] = (text, count, Date())
        ws.lastPageNotification = Date()   // suppresses the generic banner
        if isMuted(ws) { return }
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? ws.name : name
        if workspaces.count > 1 && !name.isEmpty { content.subtitle = ws.name }
        content.body = text.isEmpty ? "New message" : text
        content.sound = bannerSound ? .default : nil
        content.threadIdentifier = ws.name
        content.userInfo = ["workspace": ws.key, "conversation": conv, "name": name]
        content.categoryIdentifier = "MESSAGE"   // Reply / Mark as Read
        postBanner(content, group: "\(ws.key)|conv|\(conv)")
        bounceDock()
    }

    // A workspace went unread, its unread count rose, or it was read. Chat's
    // real alerts never reach this app (see notifyShim), so post a banner per
    // workspace and withdraw them all once read. Chat
    // exposes no sender or text here, only that -- and roughly how much -- is
    // unread.
    func notifyUnread(_ ws: Workspace) {
        guard ws.unread || ws.unreadCount > 0 else {
            let center = UNUserNotificationCenter.current()
            let prefixes = ["\(ws.key)|unread#", "\(ws.key)|conv|"]
            center.getDeliveredNotifications { delivered in
                center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }
                    .filter { id in prefixes.contains { id.hasPrefix($0) } })
            }
            return
        }
        if let t = ws.lastPageNotification, Date().timeIntervalSince(t) < 10 { return }
        if isMuted(ws) { return }
        let content = UNMutableNotificationContent()
        content.title = ws.name
        content.body = ws.unreadCount > 1
            ? "\(ws.unreadCount) unread messages in Google Chat"
            : "New message in Google Chat"
        content.sound = bannerSound ? .default : nil
        content.threadIdentifier = ws.name
        content.userInfo = ["workspace": ws.key]
        postBanner(content, group: "\(ws.key)|unread")
        bounceDock()
    }

    // Show banners while the app is frontmost too, except for the workspace
    // that is already on screen (Chat itself is visible there).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let key = notification.request.content.userInfo["workspace"]
        DispatchQueue.main.async {
            let ws = self.workspace(forKey: key)
            let onScreen = NSApp.isActive && self.window.isVisible && ws != nil && ws === self.current
            completionHandler(onScreen ? [] : [.banner, .sound, .list])
        }
    }

    // Banner clicked: bring the window up on that workspace and fire the page's
    // own click handler so Chat opens the conversation.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        DispatchQueue.main.async {
            defer { completionHandler() }
            let ws = self.workspace(forKey: info["workspace"])
            let conv = (info["conversation"] as? String) ?? ""
            switch action {
            case "MARK_READ":
                if let ws = ws, !conv.isEmpty { self.markRead(ws, conv) }
                return
            case "REPLY":
                guard let ws = ws, !conv.isEmpty, let text = replyText, !text.isEmpty else { return }
                self.showWindow(ws)
                self.sendReply(ws, conv, (info["name"] as? String) ?? "", text)
                return
            default: break
            }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            guard let ws = ws else { return }
            self.select(ws)
            if let conv = info["conversation"] as? String { self.openConversation(ws, conv) }
            // ids are "<ms>-<seq>" from the shim; checked before splicing into JS.
            if let id = info["pageID"] as? String, id.allSatisfy({ $0.isNumber || $0 == "-" }) {
                let frame = self.notifFrames.removeValue(forKey: id)
                ws.webView.evaluateJavaScript("window.__chatNotifClick && window.__chatNotifClick('\(id)')",
                                              in: frame, in: .page)
            }
        }
    }

    // Open a conversation by clicking its row (sidebar or Home list) in the page.
    // If the page has no row for it (the inbox can come from the hidden Home
    // view), load the conversation's URL instead: /app/chat/<id>, where the id
    // is the part after "dm/" or "space/".
    // `then` runs once the switch has started: right after the row click
    // (`clicked` true), or -- for a URL load, which replaces the page and any
    // script running in it -- only once that navigation has finished.
    func openConversation(_ ws: Workspace, _ conv: String, then: ((_ clicked: Bool) -> Void)? = nil) {
        ws.webView.callAsyncJavaScript(#"""
            const sel = '[role=listitem][data-group-id="' + CSS.escape(conv) + '"]';
            const row = document.querySelector(sel + ' [role=link]') || document.querySelector(sel);
            if (row) row.click();
            return !!row;
            """#, arguments: ["conv": conv], in: nil, in: .page) { [weak self] result in
            guard let self = self else { return }
            if (try? result.get()) as? Bool == true { then?(true); return }
            guard let url = self.conversationURL(ws, conv), let nav = ws.webView.load(URLRequest(url: url)) else {
                then?(false)
                return
            }
            if let then = then { self.afterLoad[ObjectIdentifier(nav)] = { then(false) } }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        afterLoad.removeValue(forKey: ObjectIdentifier(navigation))?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        afterLoad.removeValue(forKey: ObjectIdentifier(navigation))?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        afterLoad.removeValue(forKey: ObjectIdentifier(navigation))?()
    }

    func conversationURL(_ ws: Workspace, _ conv: String) -> URL? {
        guard let id = conv.split(separator: "/").last,
              id.allSatisfy({ $0.isLetter || $0.isNumber || "_-".contains($0) }) else { return nil }
        return URL(string: "https://\(ws.host)/app/chat/\(id)")
    }

    // Reply from a banner: open the conversation, put the text in Chat's
    // message box and press Send. It only types once the page is showing the
    // right conversation (its URL ends in the conversation id); on any doubt
    // it stops, and the reply goes to the clipboard instead, so nothing is
    // ever sent to the wrong place or lost.
    var replySendsImmediately: Bool { UserDefaults.standard.bool(forKey: "ReplySendsImmediately") }

    func sendReply(_ ws: Workspace, _ conv: String, _ name: String, _ text: String) {
        let path = ws.webView.url?.path ?? ""
        if path.hasSuffix("/" + (conv.split(separator: "/").last.map(String.init) ?? "-")) {
            typeReply(ws, conv, name, text, afterClick: false)
        } else {
            openConversation(ws, conv) { [weak self] clicked in
                self?.typeReply(ws, conv, name, text, afterClick: clicked)
            }
        }
    }

    // Types the reply into the conversation's message box and, if enabled in
    // Settings, presses Send (by default it leaves the reply for you to check
    // and send). Chat updates the URL before it renders the new conversation,
    // so the URL alone is not enough: the box must be labelled "Message
    // <conversation name>", or -- when the name is unknown or worded
    // differently -- be a "Message ..." box that was not already there before
    // the row click (the previous conversation's).
    func typeReply(_ ws: Workspace, _ conv: String, _ name: String, _ text: String, afterClick: Bool) {
        ws.webView.callAsyncJavaScript(#"""
            const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
            const visible = (e) => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));
            const want = '/' + conv.split('/').pop();
            const editors = () => [...document.querySelectorAll('[role=textbox][contenteditable=true]')];
            const stale = new Set(afterClick ? editors() : []);
            const label = (b) => b.getAttribute('aria-label') || '';
            let box = null;
            // Up to 20 s for Chat to render the conversation.
            for (const until = Date.now() + 20000; Date.now() < until; await sleep(150)) {
              if (!location.pathname.endsWith(want)) continue;
              const boxes = editors().filter(visible).filter((b) => /^Message /.test(label(b)));
              box = boxes.find((b) => name && label(b) === 'Message ' + name)
                 || boxes.find((b) => !stale.has(b));
              if (box) break;
            }
            if (!box) return 'message box not found';
            box.focus();
            document.execCommand('insertText', false, text);
            if (!box.innerText.trim()) {
              const data = new DataTransfer();
              data.setData('text/plain', text);
              box.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
            }
            if (!box.innerText.trim()) return 'could not type into the message box';
            if (!sendNow) return 'typed';
            for (const until = Date.now() + 3000; Date.now() < until; await sleep(100)) {
              const send = [...document.querySelectorAll('button[aria-label="Send message"]')]
                .find((b) => visible(b) && !b.disabled);
              if (send) { send.click(); return 'sent'; }
            }
            return 'send button not found';
            """#, arguments: ["conv": conv, "text": text, "name": name, "afterClick": afterClick,
                              "sendNow": replySendsImmediately], in: nil, in: .page) { [weak self] result in
            let outcome = (try? result.get()) as? String
            guard outcome != "sent", outcome != "typed" else { return }
            chatLog.warning("Reply failed: \(outcome ?? "no result", privacy: .public)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Couldn't put your reply in the conversation"
            alert.informativeText = "Chats opened the conversation but \(outcome ?? "the page did not respond"). "
                + "Your reply is on the clipboard -- paste it into the message box."
            if let win = self?.window { alert.beginSheetModal(for: win) } else { alert.runModal() }
        }
    }

    // Mark as Read from a banner, without bringing the app forward: Chat's
    // Home list has a "Mark as read" button on each unread row. If the row is
    // not on the Home list, open the conversation instead (which reads it),
    // still in the background.
    func markRead(_ ws: Workspace, _ conv: String) {
        // The hidden Home view (if any) has the Home list, so try it first.
        (ws.watcher ?? ws.webView).callAsyncJavaScript(#"""
            const sel = '[role=listitem][data-group-id="' + CSS.escape(conv) + '"]';
            const button = document.querySelector(sel + ' [aria-label="Mark as read"]');
            if (button) { button.click(); return true; }
            return false;
            """#, arguments: ["conv": conv], in: nil, in: .page) { [weak self] result in
            if (try? result.get()) as? Bool == true { return }
            chatLog.info("Mark as Read: no Home-list button; opening the conversation instead")
            self?.openConversation(ws, conv)
        }
    }

    // The menu-bar icon's menu is rebuilt each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        inboxMenu(into: menu)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Open Chats", action: #selector(openFromMenuBar(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Chats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc func openFromMenuBar(_ sender: Any?) { showWindow() }

    // The menu-bar inbox: each workspace (click to open it) followed by its
    // unread conversations, newest first -- name, preview and count. Clicking
    // one opens that conversation.
    func inboxMenu(into menu: NSMenu) {
        let nameFont = NSFont.menuFont(ofSize: 13)
        let previewFont = NSFont.menuFont(ofSize: 11)
        var any = false
        for ws in workspaces {
            let header = NSMenu()
            workspaceMenu(into: header)
            if let item = header.items.first(where: { $0.representedObject as? Workspace === ws }) {
                header.removeItem(item)
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13)])
                menu.addItem(item)
            }
            // The count (favicon dot / Home label) can be non-zero while no
            // unread row is rendered -- a collapsed section, a virtualized list.
            let total = ws.unread ? max(ws.unreadCount, 1) : ws.unreadCount
            if ws.inbox.isEmpty && total > 0 {
                any = true
                let item = menu.addItem(withTitle: "\(total) unread \u{2014} open Chat to see them",
                                        action: #selector(openWorkspace(_:)), keyEquivalent: "")
                item.indentationLevel = 1
                item.target = self
                item.representedObject = ws
            }
            for c in ws.inbox {
                any = true
                let title = NSMutableAttributedString(
                    string: (c.name.isEmpty ? "Conversation" : c.name) + (c.count > 0 ? "  (\(c.count))" : ""),
                    attributes: [.font: nameFont])
                let preview = c.text.replacingOccurrences(of: "\n", with: " ")
                if !preview.isEmpty {
                    let short = preview.count > 60 ? String(preview.prefix(57)) + "\u{2026}" : preview
                    title.append(NSAttributedString(string: "\n" + short, attributes: [
                        .font: previewFont, .foregroundColor: NSColor.secondaryLabelColor]))
                }
                let item = menu.addItem(withTitle: c.name, action: #selector(openInboxItem(_:)), keyEquivalent: "")
                item.attributedTitle = title
                item.indentationLevel = 1
                item.target = self
                item.representedObject = InboxRef(ws: ws, conv: c.id)
            }
        }
        if !any {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "No unread messages", action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    @objc func openInboxItem(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? InboxRef else { return }
        showWindow(ref.ws)
        openConversation(ref.ws, ref.conv)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
