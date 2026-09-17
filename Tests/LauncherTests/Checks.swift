import Foundation
import Testing

@testable import Launcher

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("launcher-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeBundle(_ root: URL, _ path: String, _ values: [String: Any]) throws {
    let info = root.appendingPathComponent(path).appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
}

private func app(_ id: String, _ name: String) -> Entry {
    Entry(id: id, name: name, aliases: [], path: "/Applications/\(name).app", kind: .app)
}

@Suite struct Checks {
    @Test func catalogDiscovery() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, name, flag) in [
            ("Visible.app", "Visible", ""), ("Ghost.app", "Ghost", "LSUIElement"),
            ("Daemon.app", "Daemon", "LSBackgroundOnly"), ("Utilities/Nested.app", "Nested", ""),
            ("Visible.app/Contents/Helpers/Inner.app", "Inner", ""),
        ] {
            var values: [String: Any] = ["CFBundleIdentifier": "dev.test.\(name)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            if !flag.isEmpty {
                values[flag] = true
            }
            try writeBundle(root, path, values)
        }
        #expect(Catalog.scan(roots: [root.path], panes: nil).map(\.name) == ["Ghost", "Nested", "Visible", "Quit Launcher"])
        #expect(Catalog.cleanName("Calculator.app") == "Calculator")
        #expect(Catalog.cleanName("Calculator") == "Calculator")
        #expect(Catalog.scan(roots: ["/System/Applications"]).contains { $0.id.contains("calculator") || $0.name.lowercased().contains("calculator") })

        try writeBundle(root, "Pane.appex", ["CFBundleIdentifier": "dev.test.pane", "CFBundleName": "Pane",
                                             "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.Settings.extension.ui"]])
        try writeBundle(root, "Widget.appex", ["CFBundleIdentifier": "dev.test.widget", "CFBundleName": "Widget",
                                               "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.widgetkit-extension"]])
        let panes = Catalog.scan(roots: [], panes: root.path)
        #expect(panes.map(\.name) == ["Pane", "Quit Launcher"])
        #expect(panes.first?.kind == .settings)
        #expect(Catalog.scan(roots: []).contains { $0.kind == .settings && $0.id == "com.apple.Keyboard-Settings.extension" })

        try writeBundle(root, "Fresh.app", ["CFBundleName": "Fresh"])
        #expect(Catalog.scan(roots: [root.path], panes: nil).contains { $0.name == "Fresh" })
        try FileManager.default.removeItem(at: root.appendingPathComponent("Fresh.app"))
        #expect(!Catalog.scan(roots: [root.path], panes: nil).contains { $0.name == "Fresh" })
    }

    @Test func catalogMalformedPlists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(root, "Legacy.app", [:])
        try Data(#"{ CFBundleName = "Legacy"; }"#.utf8)
            .write(to: root.appendingPathComponent("Legacy.app/Contents/Info.plist"))
        #expect(Catalog.parse(root.appendingPathComponent("Legacy.app").path)?.name == "Legacy")

        try writeBundle(root, "Broken.app", ["CFBundleName": "Broken"])
        let broken = root.appendingPathComponent("Broken.app/Contents/Info.plist")
        try (Data(contentsOf: broken) + Data("garbage".utf8)).write(to: broken)
        #expect(Catalog.parse(root.appendingPathComponent("Broken.app").path) == nil)
    }

    @Test func aliasesAndRecency() {
        let history = History()
        #expect(!history.remember("   ", id: "chrome"))
        #expect(history.aliasesFor("chrome").isEmpty)
        history.remember("chr", id: "chrome")
        history.remember("CHR", id: "safari")
        #expect(history.aliasesFor("safari") == ["chr"])
        #expect(history.aliasesFor("chrome").isEmpty)
        history.recordAt("old", now: 0)
        history.recordAt("old", now: 0)
        history.recordAt("new", now: 20 * 86400)
        #expect(history.score("new", now: 20 * 86400) > history.score("old", now: 20 * 86400))
    }

    @Test func matchingAndSelectionOrder() {
        let history = History()
        history.remember("chr", id: "chrome")
        let apps = [app("chrome", "Google Chrome"), app("screen", "Screen Sharing"), app("notes", "Notes"), Entry.quit]
        func hits(_ query: String) -> [String] {
            Rank.query(query, apps: apps, history: history, now: 0).map(\.id)
        }
        #expect(hits("").isEmpty)
        #expect(hits("   ").isEmpty)
        #expect(hits("chr") == ["chrome"])
        #expect(hits("ch") == ["chrome"])
        #expect(hits("gce").isEmpty)
        history.remember("gc", id: "chrome")
        #expect(hits("gc") == ["chrome"])

        let ties = (0 ..< 12).map { app(String($0), "Same") }
        #expect(Rank.query("same", apps: ties, history: history, now: 0).map(\.id) == (0 ..< 8).map(String.init))
    }

    @Test func unicodeMatching() {
        let history = History()
        let unicode = [app("one", "éclair"), app("two", "e\u{301}clair"), app("three", "👩‍💻 Tool"), app("four", "ΟΣ")]
        func hits(_ query: String, _ apps: [Entry]) -> [String] {
            Rank.query(query, apps: apps, history: history, now: 0).map(\.id)
        }
        #expect(hits("é", unicode) == ["one"])
        #expect(hits("e", unicode) == ["two"])
        #expect(hits("👩", unicode) == ["three"])
        #expect(hits("ος", unicode) == ["four"])

        let plain = [app("notes", "Notes")]
        #expect(hits("\u{200B}notes", plain).isEmpty)
        #expect(hits("\u{85}notes\u{85}", plain) == ["notes"])
        #expect(lowercase("A.Σ") == "a.ς")
        #expect(lowercase("\u{200B}Σ") == "\u{200B}σ")
    }

    @Test func persistenceRoundTrip() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aliasFile = dir.appendingPathComponent("aliases.json")
        let usageFile = dir.appendingPathComponent("usage.json")
        try Data(#"{"gc":"chrome","é":"é","é":"é"}"#.utf8).write(to: aliasFile)
        try Data(#"{"apps":{"chrome":{"count":3,"last_unix":100}}}"#.utf8).write(to: usageFile)

        let loaded = History.load(dataDir: dir)
        #expect(loaded.aliasesFor("chrome") == ["gc"])
        #expect(loaded.aliasesFor("é").count == 1)
        #expect(loaded.aliasesFor("e\u{301}").count == 1)
        #expect(abs(loaded.score("chrome", now: 100) - log(4)) < 1e-12)

        loaded.record("alias", id: "id")
        loaded.record("gc", id: "notes")
        let reloaded = History.load(dataDir: dir)
        #expect(reloaded.aliasesFor("chrome").isEmpty)
        #expect(reloaded.aliasesFor("notes") == ["gc"])
        #expect(reloaded.aliasesFor("é").count == 1)
        #expect(reloaded.aliasesFor("e\u{301}").count == 1)
        #expect(reloaded.aliasesFor("id") == ["alias"])
        #expect(reloaded.score("notes", now: 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage.json.tmp").path))
    }

    @Test func bomPrefixedKeysSurviveReload() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = History.load(dataDir: dir)
        history.record("alias", id: "id")
        history.record("\u{FEFF}alias", id: "\u{FEFF}id")
        let reloaded = History.load(dataDir: dir)
        #expect(reloaded.aliasesFor("\u{FEFF}id").first?.utf8.elementsEqual("\u{FEFF}alias".utf8) == true)
        #expect(reloaded.aliasesFor("id") == ["alias"])
    }

    @Test func persistenceRejectsMalformed() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageFile = dir.appendingPathComponent("usage.json")
        for malformed in ["{", #"{"apps":{"a":{"count":true,"last_unix":0}}}"#, #"{"apps":{"a":{"count":1.5,"last_unix":0}}}"#] {
            try Data(malformed.utf8).write(to: usageFile)
            #expect(History.load(dataDir: dir).score("a", now: 0) == 0)
        }
        try Data(#"{"valid":"chrome","invalid":1}"#.utf8).write(to: dir.appendingPathComponent("aliases.json"))
        #expect(History.load(dataDir: dir).aliasesFor("chrome").isEmpty)
    }

    @Test func tilingStageCycle() throws {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 900)
        for edge in [Edge.left, .right] {
            let stages = Tile.stages(edge, screen: screen)
            #expect(stages.map(\.width) == [900, 1200, 600, 1800])
            #expect(stages.allSatisfy { $0.height == 900 && (edge == .left ? $0.minX == 0 : $0.maxX == 1800) })
            let first = try #require(stages.first)
            #expect(Tile.next(edge, current: CGRect(x: 40, y: 40, width: 200, height: 200), screen: screen) == first)
            for (index, stage) in stages.enumerated() {
                #expect(Tile.next(edge, current: stage, screen: screen) == stages[(index + 1) % stages.count])
            }
        }
    }
}
