import AppKit
import Carbon
import ImageIO

private let listWidth: CGFloat = 440
private let listRow: CGFloat = 30
private let listHeader: CGFloat = 32
private let listPad: CGFloat = 6
private let listRows = 9

@MainActor private struct ClipRow {
    private static let inset: CGFloat = 12
    private static let artHeight = listRow - 8

    let root = NSView(frame: NSRect(x: 0, y: 0, width: listWidth - listPad * 2, height: listRow))
    let highlight = NSBox(frame: NSRect(x: 2, y: 2, width: listWidth - listPad * 2 - 4, height: listRow - 4))
    let art = NSImageView(frame: NSRect(x: inset, y: 4, width: ClipRow.artHeight, height: ClipRow.artHeight))
    let label = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    init() {
        highlight.boxType = .custom
        highlight.titlePosition = .noTitle
        highlight.borderWidth = 0
        highlight.cornerRadius = 7
        highlight.fillColor = .controlAccentColor.withAlphaComponent(0.85)
        highlight.autoresizingMask = [.width, .height]
        highlight.isHidden = true
        art.imageScaling = .scaleProportionallyUpOrDown
        label.frame = NSRect(x: Self.inset, y: 6, width: listWidth - listPad * 2 - Self.inset - 44, height: 18)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        badge.frame = NSRect(x: listWidth - listPad * 2 - 40, y: 6, width: 32, height: 18)
        badge.alignment = .right
        badge.font = .systemFont(ofSize: 12)
        badge.textColor = .tertiaryLabelColor
        root.autoresizingMask = [.width, .minYMargin]
        [highlight, art, label, badge].forEach(root.addSubview)
    }

    func show(_ clip: Clip, index: Int, image: URL?, selected: Bool) {
        highlight.isHidden = !selected
        let picture = image.flatMap(Self.thumbnail)
        art.image = picture
        art.isHidden = picture == nil
        if let picture {
            art.frame = NSRect(x: Self.inset, y: 4, width: picture.size.width, height: picture.size.height)
        }
        label.isHidden = picture != nil
        label.stringValue = clip.preview
        label.textColor = selected ? .white : .labelColor
        badge.stringValue = "⌘\(index + 1)"
        badge.textColor = selected ? NSColor.white.withAlphaComponent(0.7) : .tertiaryLabelColor
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(artHeight * 8),
              ] as CFDictionary), image.height > 0 else { return nil }
        let width = artHeight * CGFloat(image.width) / CGFloat(image.height)
        return NSImage(cgImage: image, size: NSSize(width: min(width, 200).rounded(), height: artHeight))
    }
}

private final class ClipContent: NSView {
    private let field = NSTextField(labelWithString: "")
    private let rows = (0 ..< listRows).map { _ in ClipRow() }
    private var shown = 0

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: listWidth, height: ClipContent.height(rows: 0, header: false)))
        wantsLayer = true
        addSubview(GlassPanel(frame: bounds))
        field.font = .systemFont(ofSize: 15)
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.autoresizingMask = [.width, .minYMargin]
        field.isHidden = true
        addSubview(field)
        for row in rows {
            addSubview(row.root)
        }
        place(height: frame.height)
    }

    func render(_ clips: [Clip], query: String, selected: Int, image: (Clip) -> URL?) -> CGFloat {
        shown = min(clips.count, listRows)
        field.stringValue = query
        field.isHidden = query.isEmpty
        for (index, row) in rows.enumerated() {
            row.root.isHidden = index >= shown
            guard index < shown else { continue }
            row.show(clips[index], index: index, image: image(clips[index]), selected: index == selected)
        }
        return Self.height(rows: shown, header: !query.isEmpty)
    }

    func index(at point: NSPoint) -> Int? {
        (0 ..< shown).first { rowFrame(height: frame.height, index: $0).contains(point) }
    }

    func place(height: CGFloat) {
        field.frame = NSRect(x: 16, y: height - listPad - listHeader + 6, width: listWidth - 32, height: 22)
        for (index, row) in rows.enumerated() {
            row.root.frame = rowFrame(height: height, index: index)
        }
    }

    static func height(rows: Int, header: Bool) -> CGFloat {
        listPad + (header ? listHeader : 0) + CGFloat(rows) * listRow + listPad
    }

    private func rowFrame(height: CGFloat, index: Int) -> NSRect {
        let top = height - listPad - (field.isHidden ? 0 : listHeader)
        return NSRect(x: listPad, y: top - listRow * CGFloat(index + 1),
                      width: listWidth - listPad * 2, height: listRow)
    }
}

final class ClipPanel: NSPanel, NSWindowDelegate {
    private let store = Clipboard.load()
    private let list = ClipContent()
    private var clips: [Clip] = []
    private var query = ""
    private var selected = 0
    private var offset = 0
    private var caller: NSRunningApplication?
    private var anchor = NSPoint.zero

    override var canBecomeKey: Bool {
        true
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: listWidth, height: ClipContent.height(rows: 0, header: false)),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        hasShadow = true
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = list
        store.start()
    }

    func toggle() {
        isVisible ? dismiss() : present()
    }

    private func present() {
        query = ""
        selected = 0
        caller = NSWorkspace.shared.frontmostApplication
        anchor = NSEvent.mouseLocation
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        NSRunningApplication.current.hide()
    }

    func windowDidResignKey(_: Notification) {
        dismiss()
    }

    private func refresh() {
        clips = store.recent(query)
        selected = min(selected, max(0, clips.count - 1))
        offset = 0
        let height = draw()
        place(anchor, height: height)
    }

    @discardableResult
    private func draw() -> CGFloat {
        list.render(Array(clips[offset ..< min(clips.count, offset + listRows)]),
                    query: query, selected: selected - offset, image: store.image)
    }

    private func place(_ corner: NSPoint, height: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(corner) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = min(max(corner.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - listWidth - 8))
        let y = min(max(corner.y - height, visible.minY + 8), max(visible.minY + 8, visible.maxY - height - 8))
        setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: listWidth, height: height), display: true)
        list.place(height: height)
    }

    private func paste(_ index: Int) {
        guard clips.indices.contains(index) else { return }
        guard AXIsProcessTrusted() else {
            dismiss()
            return Tile.requestAccess()
        }
        dismiss()
        guard let change = store.offer(clips[index].digest) else { return }
        caller?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            Clipboard.synthesizePaste(after: change)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isVisible, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), digit >= 1, digit <= listRows
        else { return super.performKeyEquivalent(with: event) }
        paste(offset + digit - 1)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case kVK_Escape:
            dismiss()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            paste(selected)
        case kVK_DownArrow:
            move(1)
        case kVK_UpArrow:
            move(-1)
        case kVK_Delete:
            query = String(query.dropLast())
            refresh()
        default:
            let typed = event.characters ?? ""
            guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7F && !(0xF700 ... 0xF8FF).contains($0.value)
            }) else { return }
            query += typed
            refresh()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let index = list.index(at: list.convert(event.locationInWindow, from: nil)),
              selected != offset + index else { return }
        selected = offset + index
        draw()
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = list.index(at: list.convert(event.locationInWindow, from: nil)) else { return }
        paste(offset + index)
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY > 1 ? -1 : (event.scrollingDeltaY < -1 ? 1 : 0)
        guard step != 0, clips.count > listRows else { return }
        offset = min(max(0, offset + step), clips.count - listRows)
        selected = min(max(selected, offset), offset + listRows - 1)
        draw()
    }

    private func move(_ delta: Int) {
        guard !clips.isEmpty else { return }
        selected = (selected + delta + clips.count) % clips.count
        offset = min(max(offset, selected - listRows + 1), selected)
        offset = min(offset, max(0, clips.count - listRows))
        draw()
    }
}
