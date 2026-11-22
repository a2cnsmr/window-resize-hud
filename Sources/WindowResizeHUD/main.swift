// WindowResizeHUD
//
// 他のアプリのウインドウをマウスでリサイズするときに、
// ウインドウ全体を矩形で囲み、カーソルの近くにサイズ (幅 × 高さ) を表示する
// メニューバー常駐ユーティリティ。
//
// 仕組み:
//  - CGWindowList で画面上のウインドウ一覧 (位置と大きさ) を取得する
//  - ウインドウの縁 (約6pt以内、外側含む) でドラッグが始まったら、そのウインドウを
//    リサイズ候補として記録する。候補の探索は、カーソルを含む一番手前のウインドウで
//    打ち切る (背面ウインドウの誤検出防止)
//  - 押下時点のサイズを覚えておき、実際にサイズが変わった時点で初めてオーバーレイを
//    表示する (タイトルバーのクリックやウインドウ移動では表示しない)
//  - ドラッグ中は対象ウインドウだけを CGWindowList (.optionIncludingWindow) で
//    約60fps取得し、矩形と数値を追従させる
//  - オーバーレイは「対象ウインドウ＋ラベル用の余白」の大きさの小さなウインドウで、
//    対象に追従して動く (全画面1枚ではないので、マルチディスプレイでも対象のある
//    画面に描画される)
//  - マウスボタンを離したらオーバーレイを消す
//
// 注意: 他アプリのウインドウの「リサイズ開始/終了」を知らせる公式APIはないため、
// マウスの押下/ドラッグ/解放とウインドウ矩形の変化から推定している。
// マウスイベントのグローバル監視とウインドウ矩形の取得には「アクセシビリティ」
// 許可は不要 (2026-11-22、許可オフの状態で動作することを実機確認済み)。
// 許可が必要になるのはキーイベントの監視などに限られる。

import AppKit
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

/// 対象ウインドウ1つだけを取得する (ドラッグ中のポーリング用。全件取得より軽い)
func window(withID id: CGWindowID) -> WindowInfo? {
    guard
        let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
        let info = raw.first,
        let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
        let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    else { return nil }
    return WindowInfo(id: id, bounds: bounds, ownerPID: pid.int32Value)
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
    /// オーバーレイウインドウの原点 (スクリーン座標)。描画時にローカル座標へ変換する
    var windowOrigin: NSPoint = .zero
    var sizeText: String = ""

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let target = targetRectScreen else { return }
        let rect = NSRect(
            x: target.minX - windowOrigin.x,
            y: target.minY - windowOrigin.y,
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

        let mouse = NSPoint(x: mouseScreen.x - windowOrigin.x, y: mouseScreen.y - windowOrigin.y)
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y + 16)

        // ラベルは「カーソルのある画面」の内側に収める
        // (全画面のunion基準だと、どの画面にも映らない位置に出ることがある)
        var clampRect = bounds
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseScreen) }) {
            let s = NSRect(
                x: screen.frame.minX - windowOrigin.x,
                y: screen.frame.minY - windowOrigin.y,
                width: screen.frame.width,
                height: screen.frame.height
            )
            let inter = bounds.intersection(s)
            if !inter.isNull { clampRect = inter }
        }
        origin.x = min(max(origin.x, clampRect.minX + 2), clampRect.maxX - labelSize.width - 2)
        origin.y = min(max(origin.y, clampRect.minY + 2), clampRect.maxY - labelSize.height - 2)
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
    /// ラベルを表示するための余白 (対象ウインドウの周囲にこの分だけ広げる)
    /// ラベルの幅 (約100pt) + カーソルからのずらし (16pt) が収まる広さにする
    private let margin: CGFloat = 140

    private func obtainWindow() -> NSWindow {
        if let window { return window }
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
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
        let target = toNSRect(rect)
        let frame = target.insetBy(dx: -margin, dy: -margin)
        let w = obtainWindow()
        // 先に中身を更新してから、ウインドウの移動と再描画を同時に行う
        // (移動だけ先にすると、枠が1フレームずれて見えることがある)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.windowOrigin = frame.origin
        view.targetRectScreen = target
        view.mouseScreen = mouse
        view.sizeText = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        if w.frame != frame {
            w.setFrame(frame, display: true)
        } else {
            view.needsDisplay = true
        }
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
    /// 押下時点のウインドウサイズ。実際にサイズが変わるまで表示しない
    private var dragStartSize: CGSize?
    /// 一度サイズ変化を検出したら、そのドラッグ中は表示を続ける
    private var hudVisible = false
    private var pollTimer: Timer?

    func start() {
        // ホバーでは表示しない (縁をなぞるたびに出て目がちらつくため)。
        // 表示はドラッグで実際にサイズが変わってから、マウスを離すまで。
        addMonitor(.leftMouseDown) { [weak self] _ in self?.handleMouseDown() }
        addMonitor(.leftMouseDragged) { [weak self] _ in
            guard let self, self.hudVisible else { return }
            self.overlay.updateMouse(NSEvent.mouseLocation)
        }
        addMonitor(.leftMouseUp) { [weak self] _ in self?.handleMouseUp() }
    }

    private func addMonitor(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(monitor)
        }
    }

    private func handleMouseDown() {
        let cg = toCGPoint(NSEvent.mouseLocation)
        guard let target = resizeTarget(atCGPoint: cg) else { return }
        draggingID = target.id
        dragStartSize = target.bounds.size
        hudVisible = false
        startPolling()
        // ここではまだ表示しない
    }

    /// ドラッグ開始位置からリサイズ対象のウインドウを探す。
    /// 縁つかみはウインドウの数px外側 (影のあたり) で起こることが多いため、
    /// 「点を含むウインドウ」だけでなく「縁の帯 (外側含む) に点があるウインドウ」も候補にする。
    /// ただし、点を含む一番手前のウインドウより後ろのウインドウは候補から外す
    /// (前面ウインドウの内側をクリックしたのに背面ウインドウを誤検出しないため)。
    private func resizeTarget(atCGPoint cg: CGPoint) -> WindowInfo? {
        let wins = windowsFrontToBack()
        let limit = wins.firstIndex { $0.bounds.contains(cg) }.map { $0 + 1 } ?? wins.count
        let candidates = wins.prefix(limit)
        // 1) 点が内側にあり、かつ縁に近いウインドウを優先
        if let w = candidates.first(where: { $0.bounds.contains(cg) && isNearEdge(cgPoint: cg, of: $0.bounds) }) {
            return w
        }
        // 2) 点がウインドウの外側でも、縁の帯の中にあるウインドウ
        return candidates.first { isNearEdge(cgPoint: cg, of: $0.bounds) }
    }

    private func handleMouseUp() {
        draggingID = nil
        dragStartSize = nil
        hudVisible = false
        stopPolling()
        overlay.hide()
    }

    private func startPolling() {
        stopPolling()
        // グローバルモニタのハンドラはメインスレッドで呼ばれるので、そのままタイマーを作る。
        // ドラッグ中は約60fpsで対象ウインドウの矩形を追いかける
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollDraggingWindow()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollDraggingWindow() {
        guard let id = draggingID, let startSize = dragStartSize, let win = window(withID: id) else { return }
        if !hudVisible {
            // サイズが実際に変わるまでは表示しない
            // (タイトルバーのクリック、ウインドウ移動、スクロールバー操作などを除外)
            guard win.bounds.size != startSize else { return }
            hudVisible = true
        }
        overlay.show(windowRectCG: win.bounds, mouse: NSEvent.mouseLocation)
    }
}

// MARK: - アプリ本体

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tracker = ResizeTracker()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        tracker.start()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Window Resize HUD")
        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "Window Resize HUD について", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "動作中: ウインドウの縁をドラッグするとサイズを表示します", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
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
