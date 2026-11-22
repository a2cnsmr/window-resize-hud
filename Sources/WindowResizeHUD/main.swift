// WindowResizeHUD
//
// 他のアプリのウインドウをマウスでリサイズするときに、
// ウインドウ全体を矩形で囲み、カーソルの近くにサイズ (幅 × 高さ) を表示する
// メニューバー常駐ユーティリティ。
//
// 仕組み:
//  - CGWindowList で画面上のウインドウ一覧 (位置と大きさ) を取得する
//  - グローバルマウスモニタで、ウインドウの縁 (約6pt以内) でのドラッグ開始を検知し、
//    その時点でオーバーレイを表示する (ホバーでは表示しない)
//  - ドラッグ中はタイマーでウインドウの大きさをポーリングし、矩形と数値を追従させる
//  - マウスボタンを離したらオーバーレイを消す
//
// 注意: 他アプリのウインドウの「リサイズ開始/終了」を知らせる公式APIはないため、
// マウスの押下/ドラッグ/解放とウインドウ矩形の変化から推定している。
// グローバルマウスモニタには「アクセシビリティ」許可が必要。

import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - 座標変換
//
// AppKit (NSEvent / NSScreen) は左下原点、CGWindowList は左上原点 (プライマリ画面基準)。
// プライマリ画面の高さを使って相互変換する。

var primaryScreenHeight: CGFloat {
    NSScreen.screens.first?.frame.height ?? 0
}

func toCGPoint(_ point: NSPoint) -> CGPoint {
    CGPoint(x: point.x, y: primaryScreenHeight - point.y)
}

func toNSRect(_ rect: CGRect) -> NSRect {
    NSRect(
        x: rect.origin.x,
        y: primaryScreenHeight - rect.origin.y - rect.height,
        width: rect.width,
        height: rect.height
    )
}

// MARK: - ウインドウ情報

struct WindowInfo {
    let id: CGWindowID
    let bounds: CGRect // CG座標 (左上原点)
    let ownerPID: pid_t
}

func windowsFrontToBack() -> [WindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    let myPID = ProcessInfo.processInfo.processIdentifier
    var result: [WindowInfo] = []
    for info in raw {
        guard
            let number = info[kCGWindowNumber as String] as? NSNumber,
            let layer = info[kCGWindowLayer as String] as? NSNumber,
            let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
            let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { continue }

        if layer.intValue != 0 { continue }              // 通常のウインドウだけ
        if pid.int32Value == myPID { continue }           // 自分 (オーバーレイ等) は除外
        if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { continue }
        if bounds.width < 60 || bounds.height < 40 { continue } // 小さな断片は除外

        result.append(WindowInfo(id: CGWindowID(number.uint32Value), bounds: bounds, ownerPID: pid.int32Value))
    }
    return result
}

func topWindow(underCGPoint point: CGPoint) -> WindowInfo? {
    windowsFrontToBack().first { $0.bounds.contains(point) }
}

func window(withID id: CGWindowID) -> WindowInfo? {
    windowsFrontToBack().first { $0.id == id }
}

/// カーソルがウインドウの縁 (外側/内側 tolerance 以内) にあるか
func isNearEdge(cgPoint point: CGPoint, of rect: CGRect, tolerance: CGFloat = 6) -> Bool {
    let outer = rect.insetBy(dx: -tolerance, dy: -tolerance)
    guard outer.contains(point) else { return false }
    let inner = rect.insetBy(dx: tolerance, dy: tolerance)
    // 縁の帯の中にいる = 外側の矩形には入るが、内側の矩形には入らない
    return !inner.contains(point) || rect.width <= tolerance * 2 || rect.height <= tolerance * 2
}

// MARK: - オーバーレイ

final class OverlayView: NSView {
    /// 囲みたいウインドウの矩形 (AppKitのスクリーン座標)
    var targetRectScreen: NSRect?
    /// カーソル位置 (AppKitのスクリーン座標)
    var mouseScreen: NSPoint = .zero
    var sizeText: String = ""

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let target = targetRectScreen, let win = window else { return }
        // スクリーン座標 -> このビューの座標 (ウインドウの原点分を引く)
        let rect = NSRect(
            x: target.minX - win.frame.minX,
            y: target.minY - win.frame.minY,
            width: target.width,
            height: target.height
        )

        // ウインドウ全体を囲む矩形
        let outline = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        outline.fill()
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        guard !sizeText.isEmpty else { return }

        // カーソル近くにサイズを表示
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = sizeText.size(withAttributes: attributes)
        let padding: CGFloat = 8
        let labelSize = NSSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)

        let mouse = NSPoint(x: mouseScreen.x - win.frame.minX, y: mouseScreen.y - win.frame.minY)
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y + 16)
        // オーバーレイの外にはみ出さないように収める
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - labelSize.width - 2)
        origin.y = min(max(origin.y, bounds.minY + 2), bounds.maxY - labelSize.height - 2)
        let labelRect = NSRect(origin: origin, size: labelSize)

        let bg = NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        bg.fill()

        sizeText.draw(at: NSPoint(x: labelRect.minX + padding, y: labelRect.minY + padding), withAttributes: attributes)
    }
}

final class OverlayController {
    private var window: NSWindow?
    private let view = OverlayView()

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let frame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true // マウス操作を一切邪魔しない
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.animationBehavior = .none // 表示/非表示をアニメーションさせない
        w.contentView = view
        window = w
        return w
    }

    func show(windowRectCG rect: CGRect, mouse: NSPoint) {
        let w = ensureWindow()
        view.targetRectScreen = toNSRect(rect)
        view.mouseScreen = mouse
        view.sizeText = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        view.needsDisplay = true
        if !w.isVisible { w.orderFrontRegardless() }
    }

    func updateMouse(_ mouse: NSPoint) {
        view.mouseScreen = mouse
        view.needsDisplay = true
    }

    func hide() {
        view.targetRectScreen = nil
        view.sizeText = ""
        window?.orderOut(nil)
    }

    var isShowing: Bool { view.targetRectScreen != nil }
}

// MARK: - リサイズ追跡

final class ResizeTracker {
    private let overlay = OverlayController()
    private var monitors: [Any] = []
    private var draggingID: CGWindowID?
    private var pollTimer: Timer?

    func start() {
        // ホバーでは表示しない (縁をなぞるたびに出て目がちらつくため)。
        // 表示はドラッグ開始 (リサイズ開始) からマウスを離すまで。
        addMonitor(.leftMouseDown) { [weak self] _ in self?.handleMouseDown() }
        addMonitor(.leftMouseDragged) { [weak self] _ in self?.overlay.updateMouse(NSEvent.mouseLocation) }
        addMonitor(.leftMouseUp) { [weak self] _ in self?.handleMouseUp() }
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(monitor)
        }
    }

    private func handleMouseDown() {
        let mouse = NSEvent.mouseLocation
        let cg = toCGPoint(mouse)
        guard let target = resizeTarget(atCGPoint: cg) else { return }
        draggingID = target.id
        overlay.show(windowRectCG: target.bounds, mouse: mouse)
        startPolling()
    }

    /// ドラッグ開始位置からリサイズ対象のウインドウを探す。
    /// 縁つかみはウインドウの数px外側 (影のあたり) で起こることが多いため、
    /// 「点を含むウインドウ」だけでなく「縁の帯 (外側含む) に点があるウインドウ」も候補にする。
    private func resizeTarget(atCGPoint cg: CGPoint) -> WindowInfo? {
        let wins = windowsFrontToBack()
        // 1) 点が内側にあり、かつ縁に近いウインドウを優先
        if let w = wins.first(where: { $0.bounds.contains(cg) && isNearEdge(cgPoint: cg, of: $0.bounds) }) {
            return w
        }
        // 2) 点がウインドウの外側でも、縁の帯の中にあるウインドウ
        return wins.first { isNearEdge(cgPoint: cg, of: $0.bounds) }
    }

    private func handleMouseUp() {
        draggingID = nil
        stopPolling()
        overlay.hide()
    }

    private func startPolling() {
        stopPolling()
        // ドラッグ中は約60fpsでウインドウ矩形を追いかける (メインスレッドで回す)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.draggingID != nil else { return }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.pollDraggingWindow()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollDraggingWindow() {
        guard let id = draggingID, let win = window(withID: id) else { return }
        overlay.show(windowRectCG: win.bounds, mouse: NSEvent.mouseLocation)
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tracker = ResizeTracker()
    private var statusItem: NSStatusItem?
    private var trusted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        trusted = checkAccessibilityPermission(prompt: true)
        setupStatusItem()
        tracker.start()
    }

    private func checkAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Window Resize HUD")
        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "Window Resize HUD について", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        let stateTitle = trusted
            ? "動作中: ウインドウの縁をドラッグするとサイズを表示します"
            : "アクセシビリティ許可が必要です (設定後に再起動してください)"
        menu.addItem(NSMenuItem(title: stateTitle, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "アクセシビリティ設定を開く", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "ウインドウをマウスでリサイズしている間、ウインドウ全体を矩形で囲み、カーソルの近くにサイズ (幅 × 高さ) を表示するユーティリティです。",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 起動

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Dockに出ないメニューバー常駐型
app.run()
