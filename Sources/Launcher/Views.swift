import AppKit

private let panelWidth: CGFloat = 640
private let searchHeight: CGFloat = 44
private let rowHeight: CGFloat = 44
private let padding: CGFloat = 4
private let radius: CGFloat = 20
private let searchInset: CGFloat = 24
private let maxRows = 8

private final class DirectEditor: NSTextView {
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return super.keyDown(with: event) }
        let typed = event.characters ?? ""
        if typed.isEmpty {
            return
        }
        if typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700 ... 0xF8FF).contains($0.value) }) {
            insertText(typed, replacementRange: selectedRange())
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class SearchCell: NSTextFieldCell {
    private let editor: DirectEditor = {
        let editor = DirectEditor()
        editor.isFieldEditor = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        return editor
    }()

    override func fieldEditor(for _: NSView) -> NSTextView? {
        editor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centered(super.drawingRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centered(super.titleRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: view, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }

    private func centered(_ rect: NSRect) -> NSRect {
        let height = font.map { $0.ascender - $0.descender } ?? 22
        return NSRect(x: rect.minX, y: rect.minY + max(0, (rect.height - height) / 2),
                      width: rect.width, height: min(height, rect.height))
    }
}

private func panelFill(for appearance: NSAppearance) -> NSColor {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 0.72)
        : NSColor(white: 1, alpha: 0.62)
}

private final class GlassPanel: NSGlassEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = radius
        style = .regular
        tintColor = panelFill(for: effectiveAppearance)
        autoresizingMask = [.width, .height]
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tintColor = panelFill(for: effectiveAppearance)
    }
}

@MainActor private struct Row {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth - padding * 2, height: rowHeight))
    let highlight = NSBox(frame: NSRect(x: 4, y: 4, width: panelWidth - padding * 2 - 8, height: rowHeight - 8))
    let icon = NSImageView(frame: NSRect(x: 14, y: 6, width: 32, height: 32))
    let label = NSTextField(labelWithString: "")

    init() {
        highlight.boxType = .custom
        highlight.title = ""
        highlight.titlePosition = .noTitle
        highlight.borderWidth = 0
        highlight.cornerRadius = 10
        highlight.fillColor = .controlAccentColor.withAlphaComponent(0.18)
        highlight.autoresizingMask = [.width, .height]
        highlight.isHidden = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.frame = NSRect(x: 56, y: 10, width: panelWidth - padding * 2 - 72, height: 24)
        label.font = .systemFont(ofSize: 15)
        label.textColor = .labelColor
        label.drawsBackground = false
        root.autoresizingMask = [.width, .minYMargin]
        [highlight, icon, label].forEach(root.addSubview)
    }
}

final class PanelContent: NSView {
    private let search = NSTextField()
    private let rows = (0 ..< maxRows).map { _ in Row() }
    private var icons: [Data: NSImage] = [:]
    private var count = 0

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: panelWidth, height: Self.height(rows: 0)))
        wantsLayer = true
        addSubview(GlassPanel(frame: bounds))
        for row in rows {
            addSubview(row.root)
        }
        search.cell = SearchCell(textCell: "")
        search.isBezeled = false
        search.drawsBackground = false
        search.isEditable = true
        search.isSelectable = true
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 22)
        search.textColor = .labelColor
        search.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.quaternaryLabelColor,
        ])
        search.autoresizingMask = [.width, .minYMargin]
        addSubview(search)
        applyFrames(height: frame.height)
    }

    func mount(on panel: NSPanel, delegate: NSTextFieldDelegate) {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        search.delegate = delegate
        panel.contentView = self
    }

    var query: String {
        search.stringValue
    }

    func clear() {
        search.stringValue = ""
    }

    func focus(on panel: NSPanel, end: Bool) {
        panel.makeFirstResponder(search)
        if end {
            search.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        }
    }

    func render(entries: [Entry], selected: Int) -> CGFloat {
        count = min(entries.count, maxRows)
        for (index, row) in rows.enumerated() {
            row.root.isHidden = index >= count
            guard index < count else { continue }
            let entry = entries[index]
            row.highlight.isHidden = index != selected
            row.label.stringValue = entry.name
            row.icon.image = icon(for: entry)
        }
        return Self.height(rows: count)
    }

    func layout(on panel: NSPanel, height: CGFloat, visible: Bool) {
        let frame = panel.frame
        guard abs(frame.height - height) >= 0.5 else { return }
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY + frame.height - height,
                              width: panelWidth, height: height), display: true)
        applyFrames(height: height)
        if visible {
            focus(on: panel, end: true)
        }
    }

    func click(on panel: NSPanel, event: NSEvent) -> Int? {
        guard !passesClick(on: panel, event: event) else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let height = Self.height(rows: count)
        return (0 ..< count).first { Self.contains(Self.rowFrame(height: height, index: $0), point) }
    }

    func passesClick(on panel: NSPanel, event: NSEvent) -> Bool {
        event.windowNumber != panel.windowNumber || Self.contains(search.frame, convert(event.locationInWindow, from: nil))
    }

    func place(on panel: NSPanel) {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { Self.contains($0.frame, point) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = Self.height(rows: count)
        panel.setFrame(NSRect(x: visible.minX + floor((visible.width - panelWidth) / 2),
                              y: visible.minY + visible.height - height - visible.height * 0.20,
                              width: panelWidth, height: height), display: true)
    }

    static func height(rows: Int) -> CGFloat {
        padding + searchHeight + CGFloat(rows) * rowHeight + padding
    }

    private func applyFrames(height: CGFloat) {
        search.frame = NSRect(x: searchInset, y: height - padding - searchHeight,
                              width: panelWidth - searchInset * 2, height: searchHeight)
        for (index, row) in rows.enumerated() {
            row.root.frame = Self.rowFrame(height: height, index: index)
        }
    }

    private func icon(for entry: Entry) -> NSImage? {
        let key = Data(entry.id.utf8)
        if let image = icons[key] {
            return image
        }
        let image: NSImage?
        switch entry.kind {
        case .quit:
            image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        case .settings:
            image = NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app").copy() as? NSImage
            image?.size = NSSize(width: 32, height: 32)
        case .app:
            image = NSWorkspace.shared.icon(forFile: entry.path).copy() as? NSImage
            image?.size = NSSize(width: 32, height: 32)
        }
        icons[key] = image
        return image
    }

    private static func rowFrame(height: CGFloat, index: Int) -> NSRect {
        NSRect(x: padding, y: height - padding - searchHeight - rowHeight * CGFloat(index + 1),
               width: panelWidth - padding * 2, height: rowHeight)
    }

    private static func contains(_ rect: NSRect, _ point: NSPoint) -> Bool {
        point.x >= rect.minX && point.y >= rect.minY && point.x <= rect.maxX && point.y <= rect.maxY
    }
}
