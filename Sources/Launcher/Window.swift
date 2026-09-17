import AppKit

enum Edge {
    case left, right
}

enum Tile {
    private static let slop: CGFloat = 8

    static func stages(_ edge: Edge, screen: CGRect) -> [CGRect] {
        [(1, 2), (2, 3), (1, 3), (1, 1)].map { numerator, denominator in
            let width = (screen.width * numerator / denominator).rounded()
            return CGRect(x: edge == .left ? screen.minX : screen.maxX - width,
                          y: screen.minY, width: width, height: screen.height)
        }
    }

    static func next(_ edge: Edge, current: CGRect, screen: CGRect) -> CGRect {
        let frames = stages(edge, screen: screen)
        let matched = frames.firstIndex { stage in
            [stage.minX - current.minX, stage.minY - current.minY,
             stage.width - current.width, stage.height - current.height].allSatisfy { abs($0) <= slop }
        }
        return frames[matched.map { ($0 + 1) % frames.count } ?? 0]
    }

    static func snap(_ edge: Edge) {
        guard AXIsProcessTrusted() else { return requestAccess() }
        guard let window = frontWindow(), let current = frame(window), let display = screen(covering: current) else {
            fputs("Launcher: no tileable frontmost window\n", stderr)
            return
        }
        apply(window, next(edge, current: current, screen: display.visibleFrame))
    }

    private static func requestAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func child(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        attribute(owner, name).map { unsafeDowncast($0, to: AXUIElement.self) }
    }

    private static func frontWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        return child(application, kAXFocusedWindowAttribute)
            ?? child(application, kAXMainWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = attribute(window, kAXPositionAttribute), let sizeValue = attribute(window, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return flipped(CGRect(origin: origin, size: size))
    }

    private static func apply(_ window: AXUIElement, _ rect: CGRect) {
        var origin = flipped(rect).origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        for (name, value) in [(kAXSizeAttribute, extent), (kAXPositionAttribute, position), (kAXSizeAttribute, extent)] {
            AXUIElementSetAttributeValue(window, name as CFString, value)
        }
    }

    private static func flipped(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let primary = (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screen(covering frame: CGRect) -> NSScreen? {
        NSScreen.screens.map { ($0, $0.frame.intersection(frame)) }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
}
