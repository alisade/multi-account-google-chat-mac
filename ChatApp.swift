import Cocoa
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
    var unread = false

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

final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    var window: NSWindow!
    var container: NSView!
    var workspaces: [Workspace] = []
    var current: Workspace?
    var appHosts: Set<String> = ["chat.google.com"]
    var popupWindows = Set<PopupWindow>()

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

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        setupMainMenu()
        workspaces = loadWorkspaces()
        appHosts = Set(workspaces.map { $0.host }.filter { !$0.isEmpty })
        if appHosts.isEmpty { appHosts = ["chat.google.com"] }

        let frame = NSRect(x: 0, y: 0, width: 1240, height: 840)
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Chat"
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = name
        window.setFrameAutosaveName("MainWindow")
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

        // Google Chat does not put an unread count in the page title, but it does
        // swap its favicon between a "no dot" and a "dot" variant to signal unread
        // (the same signal that dots a browser tab). Watch the favicon href and
        // report has-unread to the native side, which drives the rail dot + Dock
        // badge (also shown in the Cmd+Tab switcher).
        let unreadProbe = """
        (function(){
          var last = null;
          function check(){
            var links = document.querySelectorAll('link[rel~="icon"]');
            var unread = false;
            for (var i = 0; i < links.length; i++) {
              var h = links[i].href;
              // Unread favicon is "..._favicon_dot_...", read is
              // "..._favicon_no_dot_..." -- exclude the "no_dot" form (it also
              // contains the substring "_dot_").
              if (/_dot_/.test(h) && !/no_dot/.test(h)) { unread = true; break; }
            }
            if (unread !== last) {
              last = unread;
              window.webkit.messageHandlers.badge.postMessage(unread);
            }
          }
          setInterval(check, 2000);
          check();
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: unreadProbe, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        cfg.userContentController.add(self, name: "badge")

        let wv = WKWebView(frame: .zero, configuration: cfg)
        // Present as Safari so Google's login does not flag an "insecure browser".
        wv.customUserAgent = safariUA
        wv.uiDelegate = self
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
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

        let side: CGFloat = 44
        var y: CGFloat = 12
        for ws in workspaces {
            let btn = NSButton(frame: NSRect(x: (width - side) / 2, y: y, width: side, height: side))
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
            flip.addSubview(btn)
            ws.button = btn

            let d: CGFloat = 10
            let dot = NSView(frame: NSRect(x: side - d, y: 0, width: d, height: d))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = d / 2
            dot.layer?.borderWidth = 2
            dot.layer?.borderColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
            dot.isHidden = true
            btn.addSubview(dot)
            ws.dot = dot

            y += side + 12
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

    // MARK: - Navigation / popups

    // User clicked a link: send external links to the default browser, keep the
    // app's own + Google-login navigation in-session.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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

    // Drop our reference once a popup window is gone so it can deallocate.
    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? PopupWindow { popupWindows.remove(win) }
    }

    // MARK: - Unread badge

    // The injected probe reports whether a workspace has unread (favicon "dot"
    // variant). Show a dot on that workspace's rail button, and an aggregate dot
    // on the Dock icon if ANY workspace has unread -- Google Chat exposes no
    // reliable total count, only this per-account signal.
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "badge" else { return }
        let unread = (message.body as? Bool) ?? false
        if let ws = workspaces.first(where: { $0.webView === message.webView }) {
            ws.unread = unread
            ws.dot?.isHidden = !unread
        }
        let any = workspaces.contains { $0.unread }
        NSApp.dockTile.badgeLabel = any ? "\u{25CF}" : nil   // U+25CF BLACK CIRCLE
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
