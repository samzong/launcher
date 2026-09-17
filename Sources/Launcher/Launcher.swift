import AppKit
import Carbon
import ServiceManagement

final class Launcher: NSPanel, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let content = PanelContent()
    private let history = History.load()
    private var catalog: [Entry] = []
    private var results: [Entry] = []
    private var selected = 0
    private var shownAt: UInt64?
    private var monitor: Any?
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    private static let shortcuts: [(key: Int, modifiers: Int, label: String, run: @MainActor (Launcher) -> Void)] = [
        (kVK_Space, cmdKey, "Command+Space", { $0.toggle() }),
        (kVK_ANSI_Semicolon, shiftKey | optionKey, "Shift+Option+Semicolon", { _ in Tile.snap(.left) }),
        (kVK_ANSI_Quote, shiftKey | optionKey, "Shift+Option+Quote", { _ in Tile.snap(.right) }),
    ]

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: PanelContent.height(rows: 0)),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        content.mount(on: self, delegate: self)
    }

    func applicationDidFinishLaunching(_: Notification) {
        installMenu()
        registerShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.handle(event) == false ? nil : event
        }
        if Bundle.main.bundleURL.pathExtension == "app", SMAppService.mainApp.status == .notRegistered {
            do {
                try SMAppService.mainApp.register()
            } catch {
                fputs("Launcher: login item register failed: \(error)\n", stderr)
            }
        }
    }

    private func registerShortcuts() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var pressed = EventHotKeyID()
            guard let context, let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                let index = Int(pressed.id) - 1
                guard Launcher.shortcuts.indices.contains(index) else { return }
                Launcher.shortcuts[index].run(Unmanaged<Launcher>.fromOpaque(context).takeUnretainedValue())
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            fputs("Launcher: could not create hotkey manager\n", stderr)
            return
        }
        for (index, shortcut) in Launcher.shortcuts.enumerated() {
            var hotkey: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.key), UInt32(shortcut.modifiers),
                                             EventHotKeyID(signature: 0x4C43_4852, id: UInt32(index + 1)),
                                             GetApplicationEventTarget(), 0, &hotkey)
            if result == noErr, let hotkey {
                hotkeys.append(hotkey)
            } else {
                fputs("Launcher: \(shortcut.label) unavailable: OSStatus \(result)\n", stderr)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_: Notification) {
        for hotkey in hotkeys {
            UnregisterEventHotKey(hotkey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func windowDidResignKey(_: Notification) {
        if let shownAt, DispatchTime.now().uptimeNanoseconds - shownAt >= 300_000_000 {
            dismiss()
        }
    }

    func controlTextDidChange(_: Notification) {
        refresh()
    }

    func toggle() {
        shownAt == nil ? present() : dismiss()
    }

    private func present() {
        let now = DispatchTime.now().uptimeNanoseconds
        let hidden = Store.hidden()
        catalog = Catalog.applyDisplayNames(Catalog.scan().filter { $0.kind == .quit || !hidden.contains($0.id as NSString) })
        content.clear()
        shownAt = now
        refresh()
        content.place(on: self)
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        content.focus(on: self, end: false)
    }

    private func dismiss() {
        guard shownAt != nil else { return }
        shownAt = nil
        orderOut(nil)
        NSRunningApplication.current.hide()
    }

    private func refresh() {
        results = Rank.query(content.query, apps: catalog, history: history, now: Int64(max(0, Date().timeIntervalSince1970)))
        selected = 0
        render()
    }

    private func render() {
        let height = content.render(entries: results, selected: selected)
        content.layout(on: self, height: height, visible: shownAt != nil)
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
        render()
    }

    private func launch(_ index: Int? = nil) {
        if let index {
            selected = index
        }
        guard results.indices.contains(selected) else { return }
        let entry = results[selected]
        if entry.kind != .quit {
            history.record(content.query, id: entry.id)
        }
        dismiss()
        switch entry.kind {
        case .quit:
            NSApp.terminate(nil)
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:\(entry.id)") {
                NSWorkspace.shared.open(url)
            }
        case .app:
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: entry.path), configuration: config)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard shownAt != nil else { return true }
        switch event.type {
        case .keyDown where !event.modifierFlags.contains(.command):
            switch Int(event.keyCode) {
            case kVK_Escape: dismiss()
            case kVK_Return, kVK_ANSI_KeypadEnter: launch()
            case kVK_DownArrow: moveSelection(1)
            case kVK_UpArrow: moveSelection(-1)
            default: return true
            }
        case .leftMouseDown:
            if let index = content.click(on: self, event: event) {
                launch(index)
            } else {
                return content.passesClick(on: self, event: event)
            }
        default: return true
        }
        return false
    }

    private func installMenu() {
        let bar = NSMenu()
        for entries in [[("Quit", "terminate:", "q", false)], [
            ("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true),
            ("Cut", "cut:", "x", false), ("Copy", "copy:", "c", false),
            ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false),
        ]] {
            let menu = NSMenu()
            for (title, action, key, shift) in entries {
                let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
                if shift {
                    item.keyEquivalentModifierMask = [.command, .shift]
                }
                menu.addItem(item)
            }
            let parent = NSMenuItem()
            parent.submenu = menu
            bar.addItem(parent)
        }
        NSApp.mainMenu = bar
    }

    required init?(coder _: NSCoder) {
        nil
    }
}
