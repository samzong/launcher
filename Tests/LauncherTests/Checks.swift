import Foundation
import Testing

@testable import Launcher

@Suite struct Checks {
    @Test func behavior() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("launcher-checks-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        func bundle(_ path: String, _ values: [String: Any]) throws {
            let info = root.appendingPathComponent(path).appendingPathComponent("Contents/Info.plist")
            try files.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
        }
        for (path, name, flag) in [
            ("Visible.app", "Visible", ""), ("Ghost.app", "Ghost", "LSUIElement"),
            ("Daemon.app", "Daemon", "LSBackgroundOnly"), ("Utilities/Nested.app", "Nested", ""),
            ("Visible.app/Contents/Helpers/Inner.app", "Inner", ""),
        ] {
            var values: [String: Any] = ["CFBundleIdentifier": "dev.test.\(name)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            if !flag.isEmpty {
                values[flag] = true
            }
            try bundle(path, values)
        }
        let catalog = Catalog.scan(roots: [root.path], panes: nil)
        precondition(catalog.map(\.name) == ["Ghost", "Nested", "Visible", "Quit Launcher"])
        precondition(Catalog.cleanName("Calculator.app") == "Calculator")
        precondition(Catalog.cleanName("Calculator") == "Calculator")
        precondition(Catalog.scan(roots: ["/System/Applications"]).contains { $0.id.contains("calculator") || $0.name.lowercased().contains("calculator") })
        try bundle("Pane.appex", ["CFBundleIdentifier": "dev.test.pane", "CFBundleName": "Pane",
                                  "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.Settings.extension.ui"]])
        try bundle("Widget.appex", ["CFBundleIdentifier": "dev.test.widget", "CFBundleName": "Widget",
                                    "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.widgetkit-extension"]])
        let panes = Catalog.scan(roots: [], panes: root.path)
        precondition(panes.map(\.name) == ["Pane", "Quit Launcher"] && panes.first?.kind == .settings)
        precondition(Catalog.scan(roots: []).contains { $0.kind == .settings && $0.id == "com.apple.Keyboard-Settings.extension" })
        try bundle("Fresh.app", ["CFBundleName": "Fresh"])
        precondition(Catalog.scan(roots: [root.path], panes: nil).contains { $0.name == "Fresh" })
        try files.removeItem(at: root.appendingPathComponent("Fresh.app"))
        precondition(!Catalog.scan(roots: [root.path], panes: nil).contains { $0.name == "Fresh" })

        try bundle("Legacy.app", [:])
        let legacy = root.appendingPathComponent("Legacy.app/Contents/Info.plist")
        try Data(#"{ CFBundleName = "Legacy"; }"#.utf8).write(to: legacy)
        precondition(Catalog.parse(root.appendingPathComponent("Legacy.app").path)?.name == "Legacy")
        try bundle("Broken.app", ["CFBundleName": "Broken"])
        let broken = root.appendingPathComponent("Broken.app/Contents/Info.plist")
        try (Data(contentsOf: broken) + Data("garbage".utf8)).write(to: broken)
        precondition(Catalog.parse(root.appendingPathComponent("Broken.app").path) == nil)

        func app(_ id: String, _ name: String) -> Entry {
            Entry(id: id, name: name, aliases: [], path: "/Applications/\(name).app", kind: .app)
        }
        let history = History()
        precondition(!history.remember("   ", id: "chrome"))
        precondition(history.aliasesFor("chrome").isEmpty)
        history.remember("chr", id: "chrome")
        history.remember("CHR", id: "safari")
        precondition(history.aliasesFor("safari") == ["chr"] && history.aliasesFor("chrome").isEmpty)
        history.recordAt("old", now: 0)
        history.recordAt("old", now: 0)
        history.recordAt("new", now: 20 * 86400)
        precondition(history.score("new", now: 20 * 86400) > history.score("old", now: 20 * 86400))
        let apps = [app("chrome", "Google Chrome"), app("screen", "Screen Sharing"), app("notes", "Notes"), Entry.quit]
        func hits(_ query: String) -> [String] {
            Rank.query(query, apps: apps, history: history, now: 0).map(\.id)
        }
        precondition(hits("").isEmpty && hits("   ").isEmpty)
        precondition(hits("chr") == ["chrome"] && hits("ch") == ["chrome"])
        precondition(hits("gce").isEmpty)
        history.remember("gc", id: "chrome")
        precondition(hits("gc") == ["chrome"])
        let ties = (0 ..< 12).map { app(String($0), "Same") }
        precondition(Rank.query("same", apps: ties, history: history, now: 0).map(\.id) == (0 ..< 8).map(String.init))
        let unicode = [app("one", "éclair"), app("two", "e\u{301}clair"), app("three", "👩‍💻 Tool"), app("four", "ΟΣ")]
        precondition(Rank.query("é", apps: unicode, history: history, now: 0).map(\.id) == ["one"])
        precondition(Rank.query("e", apps: unicode, history: history, now: 0).map(\.id) == ["two"])
        precondition(Rank.query("👩", apps: unicode, history: history, now: 0).map(\.id) == ["three"])
        precondition(Rank.query("ος", apps: unicode, history: history, now: 0).map(\.id) == ["four"])
        precondition(hits("\u{200B}notes").isEmpty && hits("\u{85}notes\u{85}") == ["notes"])

        precondition(lowercase("A.Σ") == "a.ς" && lowercase("\u{200B}Σ") == "\u{200B}σ")
        let dir = root.appendingPathComponent("history")
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let aliasFile = dir.appendingPathComponent("aliases.json")
        let usageFile = dir.appendingPathComponent("usage.json")
        try Data(#"{"gc":"chrome","é":"é","e\u0301":"e\u0301"}"#.utf8).write(to: aliasFile)
        try Data(#"{"apps":{"chrome":{"count":3,"last_unix":100}}}"#.utf8).write(to: usageFile)
        let loaded = History.load(dataDir: dir)
        precondition(loaded.aliasesFor("chrome") == ["gc"])
        precondition(loaded.aliasesFor("é").count == 1 && loaded.aliasesFor("e\u{301}").count == 1)
        precondition(abs(loaded.score("chrome", now: 100) - log(4)) < 1e-12)
        loaded.record("alias", id: "id")
        loaded.record("\u{FEFF}alias", id: "\u{FEFF}id")
        precondition(History.load(dataDir: dir).aliasesFor("\u{FEFF}id").first?.utf8.elementsEqual("\u{FEFF}alias".utf8) == true)
        precondition(History.load(dataDir: dir).aliasesFor("id") == ["alias"])
        loaded.record("gc", id: "notes")
        let reloaded = History.load(dataDir: dir)
        precondition(reloaded.aliasesFor("chrome").isEmpty && reloaded.aliasesFor("notes") == ["gc"])
        precondition(reloaded.aliasesFor("é").count == 1 && reloaded.aliasesFor("e\u{301}").count == 1)
        precondition(reloaded.score("notes", now: 0) > 0)
        precondition(!files.fileExists(atPath: dir.appendingPathComponent("usage.json.tmp").path))
        for malformed in ["{", #"{"apps":{"a":{"count":true,"last_unix":0}}}"#, #"{"apps":{"a":{"count":1.5,"last_unix":0}}}"#] {
            try Data(malformed.utf8).write(to: usageFile)
            precondition(History.load(dataDir: dir).score("a", now: 0) == 0)
        }
        try Data(#"{"valid":"chrome","invalid":1}"#.utf8).write(to: aliasFile)
        precondition(History.load(dataDir: dir).aliasesFor("chrome").isEmpty)

        let screen = CGRect(x: 0, y: 0, width: 1800, height: 900)
        for edge in [Edge.left, .right] {
            let stages = Tile.stages(edge, screen: screen)
            precondition(stages.map(\.width) == [900, 1200, 600, 1800])
            precondition(stages.allSatisfy { $0.height == 900 && (edge == .left ? $0.minX == 0 : $0.maxX == 1800) })
            precondition(Tile.next(edge, current: CGRect(x: 40, y: 40, width: 200, height: 200), screen: screen) == stages[0])
            for (index, stage) in stages.enumerated() {
                precondition(Tile.next(edge, current: stage, screen: screen) == stages[(index + 1) % stages.count])
            }
        }
        print("PASS: catalog freshness, matching, selection order, aliases, recency, persistence and tiling")
    }
}
