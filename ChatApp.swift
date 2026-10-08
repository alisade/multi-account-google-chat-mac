import Carbon.HIToolbox
import Cocoa
import Network
import ServiceManagement
import UniformTypeIdentifiers
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
    var lastBanner: [String: (text: String, at: Date)] = [:]   // per conversation, for de-duplication
    var configIndex = 0               // position in workspaces.conf, for the default colour

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
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"

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
    var accentBar: NSView?                 // strip across the top in the current workspace's colour
    var statusItem: NSStatusItem?          // menu-bar icon
    var hotKeyRef: EventHotKeyRef?         // global show/hide shortcut
    var pathMonitor: NWPathMonitor?
    var offlineSince: Date?
    var asleepSince: Date?
    var reloadWhenOnline = false           // woke while offline: reload once the network is back

    // MARK: - Workspace config

    // Multi-workspace list from Info.plist "Workspaces", else a single workspace
    // from "AppStartURL" (the classic single-site app).
    func loadWorkspaces() -> [Workspace] {
        if let arr = Bundle.main.object(forInfoDictionaryKey: "Workspaces") as? [[String: Any]], !arr.isEmpty {
            let list: [Workspace] = arr.compactMap { d in
                guard let name = d["Name"] as? String,
                      let urlStr = d["URL"] as? String,
                      let url = URL(string: urlStr) else { return nil }
                let ws = Workspace(name: name, url: url)
                ws.storeID = (d["StoreID"] as? String).flatMap { UUID(uuidString: $0) }
                ws.iconFile = d["Icon"] as? String
                return ws
            }
            for (i, ws) in list.enumerated() { ws.configIndex = i }
            return list
        }
        let s = (Bundle.main.object(forInfoDictionaryKey: "AppStartURL") as? String) ?? "https://chat.google.com/"
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Chat"
        return [Workspace(name: name, url: URL(string: s)!)]
    }

    // The rail order the user picked (right-click > Move Up/Down), by workspace
    // key. Workspaces not in the saved list (e.g. newly added to the config)
    // keep their config order after the saved ones.
    func applySavedOrder(_ list: [Workspace]) -> [Workspace] {
        let saved = UserDefaults.standard.stringArray(forKey: "WorkspaceOrder") ?? []
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.enumerated().sorted { a, b in
            (rank[a.element.key] ?? saved.count + a.offset) < (rank[b.element.key] ?? saved.count + b.offset)
        }.map { $0.element }
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
        for (title, action) in [("Launch at Login", #selector(toggleLaunchAtLogin(_:))),
                                ("Show in Menu Bar", #selector(toggleMenuBarIcon(_:)))] {
            appMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        let hotKeyInfo = appMenu.addItem(withTitle: "Show/Hide from Anywhere: \u{2303}\u{2325}C", action: nil, keyEquivalent: "")
        hotKeyInfo.isEnabled = false
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
        editMenu.addItem(NSMenuItem.separator())
        // Cmd+F, not Cmd+K: in Chat's message box Cmd+K inserts a link.
        editMenu.addItem(withTitle: "Search Chat", action: #selector(focusSearch(_:)), keyEquivalent: "f").target = self

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
        add(viewMenu, "Reload", #selector(reloadPage(_:)), "r")
        viewMenu.addItem(NSMenuItem.separator())
        add(viewMenu, "Actual Size", #selector(zoomReset(_:)), "0")
        add(viewMenu, "Zoom In", #selector(zoomIn(_:)), "=")
        add(viewMenu, "Zoom Out", #selector(zoomOut(_:)), "-")

        // Cmd+1..9 jump to a workspace, as in Slack and browser tabs.
        if workspaces.count > 1 {
            let wsItem = NSMenuItem()
            mainMenu.addItem(wsItem)
            let wsMenu = NSMenu(title: "Workspace")
            wsItem.submenu = wsMenu
            for (i, ws) in workspaces.enumerated() {
                add(wsMenu, ws.name, #selector(selectWorkspaceFromMenu(_:)), i < 9 ? "\(i + 1)" : "", tag: i)
            }
            wsMenu.addItem(NSMenuItem.separator())
            add(wsMenu, "Next Workspace", #selector(nextWorkspace(_:)), "]", [.command, .shift])
            add(wsMenu, "Previous Workspace", #selector(previousWorkspace(_:)), "[", [.command, .shift])
        }

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
        workspaces = applySavedOrder(loadWorkspaces())
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
        let last = UserDefaults.standard.string(forKey: "LastWorkspace")
        if let ws = workspaces.first(where: { $0.name == last }) ?? workspaces.first { select(ws) }

        // Accent strip across the top of the page, in the current workspace's
        // colour, so it is obvious which account you are typing into.
        let bar = NSView(frame: NSRect(x: 0, y: container.bounds.height - 3, width: container.bounds.width, height: 3))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.isHidden = !multi
        container.addSubview(bar)
        accentBar = bar
        if let ws = current { select(ws) }   // paint the accent now that the bar exists

        window.center()
        window.makeKeyAndOrderFront(nil)

        if UserDefaults.standard.object(forKey: "ShowMenuBarIcon") as? Bool ?? true { installStatusItem() }
        registerGlobalHotKey()
        watchSleepAndNetwork()
        // Refresh mute/quiet-hours state on the rail, menu bar and Dock.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.updateBadges() }

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
        // Reply and Mark as Read on message banners. Reply brings the app forward:
        // Chat only opens a conversation while its page is on screen.
        center.setNotificationCategories([UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [.foreground],
                                                    textInputButtonTitle: "Send", textInputPlaceholder: "Reply"),
                      UNNotificationAction(identifier: "MARK_READ", title: "Mark as Read", options: [])],
            intentIdentifiers: [], options: [])])

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

          function conversations() {
            var map = {};
            var rows = document.querySelectorAll('[role=listitem][data-group-id][data-display-timestamp]');
            for (var i = 0; i < rows.length; i++) {
              var r = rows[i], id = r.getAttribute('data-group-id');
              var ts = parseInt(r.getAttribute('data-display-timestamp'), 10) || 0;
              var nm = /(\d+)\s+Notifications?/.exec(r.innerText || '');
              var c = map[id] || (map[id] = { id: id, ts: 0, alerts: 0, name: '', text: '' });
              c.ts = Math.max(c.ts, ts);
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

            // A conversation is new news if its timestamp moved past what we
            // last saw (or, first time we see it, past when the page loaded --
            // rows also appear when the list scrolls or finishes loading).
            var messages = [], convs = conversations();
            for (var id in convs) {
              var c = convs[id], prev = seen[id];
              var fresh = prev === undefined ? c.ts > startedAt : c.ts > prev;
              if (fresh && c.alerts > 0) messages.push({ id: c.id, name: c.name, text: c.text });
              seen[id] = Math.max(prev || 0, c.ts);
            }

            var key = unread + ':' + count;
            if (key !== last || messages.length) {
              last = key;
              window.webkit.messageHandlers.badge.postMessage({ unread: unread, count: count, messages: messages });
            }
          }
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
        // Safari > Develop > Chats lists each workspace page for debugging.
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        let zoom = UserDefaults.standard.double(forKey: "Zoom.\(ws.name)")
        if zoom > 0 { wv.pageZoom = zoom }
        return wv
    }

    // MARK: - Workspace rail

    func buildRail(in root: NSView, width: CGFloat, height: CGFloat) {
        let rail = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        rail.autoresizingMask = [.height]
        rail.wantsLayer = true
        rail.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        root.addSubview(rail)

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
            dot.layer?.borderColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
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
        items([("Move Up", #selector(moveWorkspaceUp(_:))),
               ("Move Down", #selector(moveWorkspaceDown(_:))),
               ("", nil),
               ("Change Logo\u{2026}", #selector(changeLogo(_:))),
               ("Reset Logo", #selector(resetLogo(_:))),
               ("", nil)], into: menu)

        let colorMenu = NSMenu()
        for (i, c) in Self.palette.enumerated() {
            let item = colorMenu.addItem(withTitle: c.name, action: #selector(setAccent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws
            item.tag = i
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                c.color.setFill(); NSBezierPath(ovalIn: r).fill(); return true
            }
        }
        menu.addItem(withTitle: "Color", action: nil, keyEquivalent: "").submenu = colorMenu

        let notifMenu = NSMenu()
        items([("Mute for 1 Hour", #selector(muteHour(_:))),
               ("Mute Until Tomorrow", #selector(muteTomorrow(_:))),
               ("Mute", #selector(muteIndefinitely(_:))),
               ("Unmute", #selector(unmute(_:))),
               ("", nil),
               ("Quiet Hours (Evenings & Weekends)", #selector(toggleQuietHours(_:)))], into: notifMenu)
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
        default: break
        }
        guard let ws = item.representedObject as? Workspace,
              let i = workspaces.firstIndex(where: { $0 === ws }) else { return true }
        let d = UserDefaults.standard
        switch item.action {
        case #selector(moveWorkspaceUp(_:)): return i > 0
        case #selector(moveWorkspaceDown(_:)): return i < workspaces.count - 1
        case #selector(resetLogo(_:)): return FileManager.default.fileExists(atPath: customLogoURL(ws).path)
        case #selector(setAccent(_:)):
            item.state = accentIndex(ws) == item.tag ? .on : .off
            return true
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

    // MARK: - Accent colours

    static let palette: [(name: String, color: NSColor)] = [
        ("Blue", .systemBlue), ("Green", .systemGreen), ("Orange", .systemOrange),
        ("Purple", .systemPurple), ("Pink", .systemPink), ("Teal", .systemTeal),
        ("Red", .systemRed), ("Yellow", .systemYellow),
    ]

    // Saved choice (right-click > Color), else a distinct default per position
    // in workspaces.conf.
    func accentIndex(_ ws: Workspace) -> Int {
        let saved = UserDefaults.standard.object(forKey: "Accent.\(ws.key)") as? Int
        return min(saved ?? ws.configIndex, Self.palette.count - 1) % Self.palette.count
    }

    func accent(_ ws: Workspace) -> NSColor { Self.palette[accentIndex(ws)].color }

    @objc func setAccent(_ sender: NSMenuItem) {
        guard let ws = sender.representedObject as? Workspace else { return }
        UserDefaults.standard.set(sender.tag, forKey: "Accent.\(ws.key)")
        if let cur = current { select(cur) }
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
    @objc func muteTomorrow(_ sender: NSMenuItem) {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        setMute(sender, until: cal.date(bySettingHour: quietHours.end, minute: 0, second: 0, of: tomorrow))
    }

    @objc func toggleQuietHours(_ sender: NSMenuItem) {
        guard let ws = sender.representedObject as? Workspace else { return }
        let key = "QuietHours.\(ws.key)"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        updateBadges()
    }

    // Quiet hours: weekends, and weekdays before `end` or from `start` on.
    // Defaults 18:00-08:00; override with
    //   defaults write <bundle-id> QuietHoursStart -int 19   (and QuietHoursEnd)
    var quietHours: (start: Int, end: Int) {
        let d = UserDefaults.standard
        return (d.object(forKey: "QuietHoursStart") as? Int ?? 18, d.object(forKey: "QuietHoursEnd") as? Int ?? 8)
    }

    // Banners and Dock bounces are skipped while muted; badges still update.
    func isMuted(_ ws: Workspace, at now: Date = Date()) -> Bool {
        let d = UserDefaults.standard
        if let until = d.object(forKey: "MuteUntil.\(ws.key)") as? Date, until > now { return true }
        guard d.bool(forKey: "QuietHours.\(ws.key)") else { return false }
        let cal = Calendar.current
        if cal.isDateInWeekend(now) { return true }
        let hour = cal.component(.hour, from: now)
        return hour >= quietHours.start || hour < quietHours.end
    }

    @objc func moveWorkspaceUp(_ sender: NSMenuItem) { moveWorkspace(sender, by: -1) }
    @objc func moveWorkspaceDown(_ sender: NSMenuItem) { moveWorkspace(sender, by: 1) }

    func moveWorkspace(_ sender: NSMenuItem, by delta: Int) {
        guard let ws = sender.representedObject as? Workspace,
              let i = workspaces.firstIndex(where: { $0 === ws }),
              workspaces.indices.contains(i + delta) else { return }
        workspaces.swapAt(i, i + delta)
        UserDefaults.standard.set(workspaces.map { $0.key }, forKey: "WorkspaceOrder")
        layoutRail()
        setupMainMenu()   // Cmd+1..9 follow the new order
    }

    // Custom logos live outside the app bundle so they survive rebuilds.
    func customLogoURL(_ ws: Workspace) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Chats")
            .appendingPathComponent("logos")
        let safe = ws.key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".png")
    }

    @objc func changeLogo(_ sender: NSMenuItem) {
        guard let ws = sender.representedObject as? Workspace else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a logo for \(ws.name) (square PNG works best)"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let src = panel.url, let self = self else { return }
            guard let img = NSImage(contentsOf: src), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                NSSound.beep()
                return
            }
            let dest = self.customLogoURL(ws)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            do {
                try png.write(to: dest)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            ws.button?.image = self.workspaceImage(ws)
        }
    }

    @objc func resetLogo(_ sender: NSMenuItem) {
        guard let ws = sender.representedObject as? Workspace else { return }
        try? FileManager.default.removeItem(at: customLogoURL(ws))
        ws.button?.image = workspaceImage(ws)
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
        var logo = NSImage(contentsOf: customLogoURL(ws))   // set via right-click > Change Logo
        if logo == nil, let f = ws.iconFile {
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
                ? accent(w).withAlphaComponent(0.7).cgColor
                : NSColor.clear.cgColor
        }
        accentBar?.layer?.backgroundColor = accent(ws).cgColor
        current = ws
        UserDefaults.standard.set(ws.name, forKey: "LastWorkspace")
        window.title = workspaces.count > 1
            ? "\((Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Chat") -- \(ws.name)"
            : ws.name
        window.makeFirstResponder(ws.webView)
    }

    // MARK: - Menu actions

    @objc func selectWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard sender.tag < workspaces.count else { return }
        window.makeKeyAndOrderFront(nil)
        select(workspaces[sender.tag])
    }

    @objc func nextWorkspace(_ sender: Any?) { stepWorkspace(1) }
    @objc func previousWorkspace(_ sender: Any?) { stepWorkspace(-1) }

    func stepWorkspace(_ delta: Int) {
        guard let cur = current, let i = workspaces.firstIndex(where: { $0 === cur }) else { return }
        let n = workspaces.count
        select(workspaces[((i + delta) % n + n) % n])
    }

    @objc func reloadPage(_ sender: Any?) { if let ws = current { reload(ws) } }

    // A reload starts the unread probe from scratch; treat its first report as
    // the baseline again so a reload never raises a banner for old unread.
    func reload(_ ws: Workspace) {
        ws.unreadReported = false
        ws.webView.reload()
    }

    // MARK: - Search, global shortcut, launch at login, menu bar

    // Focus Chat's search box. It sits in the one [role=search] landmark; when
    // collapsed, its visible button expands it, and the input only takes focus
    // once Chat's animation has drawn it.
    @objc func focusSearch(_ sender: Any?) {
        guard let ws = current else { return }
        ws.webView.callAsyncJavaScript(#"""
            const visible = (e) => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));
            const input = () => document.querySelector('input[name="q"]');
            if (!visible(input())) {
              const region = document.querySelector('[role="search"]');
              const button = region && [...region.querySelectorAll('button')].find(visible);
              if (button) button.click();
            }
            for (const until = Date.now() + 1500; Date.now() < until;) {
              const q = input();
              if (visible(q)) { q.focus(); q.select(); return true; }
              await new Promise((r) => requestAnimationFrame(r));
            }
            return false;
            """#, arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    // Ctrl+Option+C from any app shows Chats, or hides it if it is in front.
    func registerGlobalHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.toggleVisibility() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4348_4154), id: 1)   // 'CHAT'
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func toggleVisibility() {
        if NSApp.isActive && window.isVisible {
            NSApp.hide(nil)
        } else {
            showWindow()
        }
    }

    func showWindow(_ ws: Workspace? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let ws = ws { select(ws) }
    }

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "You can add Chats in System Settings > General > Login Items."
            alert.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc func toggleMenuBarIcon(_ sender: Any?) {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        } else {
            installStatusItem()
        }
        UserDefaults.standard.set(statusItem != nil, forKey: "ShowMenuBarIcon")
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
            item.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { [weak self] r in
                (self?.accent(ws) ?? .gray).setFill(); NSBezierPath(ovalIn: r).fill(); return true
            }
        }
    }

    @objc func openWorkspace(_ sender: NSMenuItem) {
        showWindow(sender.representedObject as? Workspace)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        workspaceMenu(into: menu)
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
                    if Date().timeIntervalSince(since) > 60 || self.reloadWhenOnline {
                        self.reloadWhenOnline = false
                        self.reloadAllWhenOnline()
                    }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "chats.network"))
        pathMonitor = monitor
    }

    // Wait out the first seconds after wake, when Wi-Fi is still joining.
    func reloadAllWhenOnline() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if self.offlineSince != nil { self.reloadWhenOnline = true; return }
            self.workspaces.forEach(self.reload)
        }
    }

    // WebKit killed the page's process (memory pressure, crash): reload it
    // rather than leave a blank workspace.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let ws = workspaces.first(where: { $0.webView === webView }) { reload(ws) }
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

    // Zoom applies to the current workspace and is remembered per workspace.
    @objc func zoomIn(_ sender: Any?) { setZoom { $0 + 0.1 } }
    @objc func zoomOut(_ sender: Any?) { setZoom { $0 - 0.1 } }
    @objc func zoomReset(_ sender: Any?) { setZoom { _ in 1 } }

    func setZoom(_ change: (CGFloat) -> CGFloat) {
        guard let ws = current else { return }
        let z = min(3, max(0.5, (change(ws.webView.pageZoom) * 10).rounded() / 10))
        ws.webView.pageZoom = z
        UserDefaults.standard.set(Double(z), forKey: "Zoom.\(ws.name)")
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
    // instead of overwriting an existing file.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var dest = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
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
        if let ws = workspaces.first(where: { $0.webView === message.webView }) {
            let wasUnread = ws.unread, oldCount = ws.unreadCount
            ws.unread = unread
            ws.unreadCount = count
            updateRailBadge(ws)
            // A named banner per new message when the page could tell which
            // conversation it was in; otherwise a generic one when unread starts
            // or the count goes up. Skip the first report: that is the unread
            // state at launch, not news.
            for m in messages { notifyMessage(ws, m) }
            if ws.unreadReported && (unread != wasUnread || count > oldCount) { notifyUnread(ws) }
            ws.unreadReported = true
        }
        updateBadges()
    }

    // MARK: - Desktop notifications

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
        guard type == "show", !isMuted(ws) else { return }

        notifFrames[id] = message.frameInfo
        ws.lastPageNotification = Date()
        if notifFrames.count > 200, let oldest = notifFrames.keys.min() {
            notifFrames.removeValue(forKey: oldest)   // ids start with a ms timestamp
        }

        let content = UNMutableNotificationContent()
        content.title = (body["title"] as? String) ?? ""
        content.body = (body["body"] as? String) ?? ""
        if workspaces.count > 1 { content.subtitle = ws.name }
        content.sound = .default
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
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

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
        // Chat bumps a row's timestamp several times for one message (seen: 4
        // bumps in 10 s). Skip a repeat of the same conversation + text within
        // 15 s; a different message always gets its own banner.
        if let last = ws.lastBanner[conv], last.text == text, Date().timeIntervalSince(last.at) < 15 { return }
        ws.lastBanner[conv] = (text, Date())
        ws.lastPageNotification = Date()   // suppresses the generic banner
        if isMuted(ws) { return }
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? ws.name : name
        if workspaces.count > 1 && !name.isEmpty { content.subtitle = ws.name }
        content.body = text.isEmpty ? "New message" : text
        content.sound = .default
        content.threadIdentifier = ws.name
        content.userInfo = ["workspace": ws.key, "conversation": conv]
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
        content.sound = .default
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
                self.sendReply(ws, conv, text)
                return
            default: break
            }
            NSApp.activate(ignoringOtherApps: true)
            self.window.makeKeyAndOrderFront(nil)
            guard let ws = ws else { return }
            self.select(ws)
            // Conversation ids look like "dm/y2-4eqAAAAE" or "space/AAQA..";
            // checked before splicing into JS.
            if let conv = info["conversation"] as? String,
               conv.allSatisfy({ $0.isLetter || $0.isNumber || "/_-".contains($0) }) {
                ws.webView.evaluateJavaScript("""
                    (function(){
                      var r = document.querySelector('[role=listitem][data-group-id="\(conv)"] [role=link]')
                           || document.querySelector('[role=listitem][data-group-id="\(conv)"]');
                      if (r) r.click();
                    })();
                    """)
            }
            // ids are "<ms>-<seq>" from the shim; checked before splicing into JS.
            if let id = info["pageID"] as? String, id.allSatisfy({ $0.isNumber || $0 == "-" }) {
                let frame = self.notifFrames.removeValue(forKey: id)
                ws.webView.evaluateJavaScript("window.__chatNotifClick && window.__chatNotifClick('\(id)')",
                                              in: frame, in: .page)
            }
        }
    }

    // Reply from a banner: open the conversation, put the text in Chat's
    // message box and press Send. It only types once the page is showing the
    // right conversation (its URL ends in the conversation id); on any doubt
    // it stops, and the reply goes to the clipboard instead, so nothing is
    // ever sent to the wrong place or lost.
    func sendReply(_ ws: Workspace, _ conv: String, _ text: String) {
        ws.webView.callAsyncJavaScript(#"""
            const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
            const visible = (e) => !!(e && (e.offsetWidth || e.offsetHeight || e.getClientRects().length));
            const want = '/' + conv.split('/').pop();
            const sel = '[role=listitem][data-group-id="' + CSS.escape(conv) + '"]';
            if (!location.pathname.endsWith(want)) {
              const row = document.querySelector(sel + ' [role=link]') || document.querySelector(sel);
              if (!row) return 'conversation not found';
              row.click();
            }
            let box = null;
            for (const until = Date.now() + 8000; Date.now() < until; await sleep(150)) {
              if (!location.pathname.endsWith(want)) continue;
              const boxes = [...document.querySelectorAll('[role=textbox][contenteditable=true]')].filter(visible);
              box = boxes.find((b) => /^Message /.test(b.getAttribute('aria-label') || '')) || boxes[0];
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
            for (const until = Date.now() + 3000; Date.now() < until; await sleep(100)) {
              const send = [...document.querySelectorAll('button[aria-label="Send message"]')]
                .find((b) => visible(b) && !b.disabled);
              if (send) { send.click(); return 'sent'; }
            }
            return 'send button not found';
            """#, arguments: ["conv": conv, "text": text], in: nil, in: .page) { [weak self] result in
            let outcome = (try? result.get()) as? String
            guard outcome != "sent" else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let alert = NSAlert()
            alert.messageText = "Couldn't send your reply"
            alert.informativeText = "Chats opened the conversation but \(outcome ?? "the page did not respond"). "
                + "Your reply is on the clipboard -- paste it into the message box."
            if let win = self?.window { alert.beginSheetModal(for: win) } else { alert.runModal() }
        }
    }

    // Mark as Read from a banner, without bringing the app forward: Chat's
    // Home list has a "Mark as read" button on each unread row. If the row is
    // not on the Home list, open the conversation instead (which reads it).
    func markRead(_ ws: Workspace, _ conv: String) {
        ws.webView.callAsyncJavaScript(#"""
            const sel = '[role=listitem][data-group-id="' + CSS.escape(conv) + '"]';
            const button = document.querySelector(sel + ' [aria-label="Mark as read"]');
            if (button) { button.click(); return true; }
            return false;
            """#, arguments: ["conv": conv], in: nil, in: .page) { [weak self] result in
            if (try? result.get()) as? Bool == true { return }
            self?.showWindow(ws)
            ws.webView.callAsyncJavaScript(#"""
                const sel = '[role=listitem][data-group-id="' + CSS.escape(conv) + '"]';
                const row = document.querySelector(sel + ' [role=link]') || document.querySelector(sel);
                if (row) row.click();
                """#, arguments: ["conv": conv], in: nil, in: .page, completionHandler: nil)
        }
    }

    // The menu-bar icon's menu is rebuilt each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        workspaceMenu(into: menu)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Open Chats", action: #selector(openFromMenuBar(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Chats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc func openFromMenuBar(_ sender: Any?) { showWindow() }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
