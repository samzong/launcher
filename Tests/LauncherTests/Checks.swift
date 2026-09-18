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
            ("Visible.app/Contents/Helpers/Inner.app", "Inner", ""), ("Shout.APP", "Shout", ""),
        ] {
            var values: [String: Any] = ["CFBundleIdentifier": "dev.test.\(name)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            if !flag.isEmpty {
                values[flag] = true
            }
            try writeBundle(root, path, values)
        }
        #expect(Catalog.scan(roots: [root.path], panes: nil).map(\.name) == ["Ghost", "Nested", "Shout", "Visible", "Quit Launcher"])
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

    @Test func clipEvictionWindow() {
        func clip(_ id: String, uses: UInt64, ageDays: Double) -> Clip {
            Clip(digest: id, kind: .text, bytes: 512,
                 lastUnix: 30 * 86400 - Int64(ageDays * 86400), uses: uses, preview: id)
        }
        let now: Int64 = 30 * 86400
        func kept(_ clips: [Clip]) -> [String] {
            Clips.retained(clips, now: now).map(\.digest)
        }
        #expect(kept([clip("fresh", uses: 1, ageDays: 1)]) == ["fresh"])
        #expect(kept([clip("stale", uses: 1, ageDays: 3)]).isEmpty)
        #expect(kept([clip("reused", uses: 5, ageDays: 5)]) == ["reused"])
        #expect(kept([clip("faded", uses: 2, ageDays: 40)]).isEmpty)
    }

    @Test func clipBudgetBreaker() {
        let now: Int64 = 0
        let clips = (0 ..< 10).map {
            Clip(digest: "c\($0)", kind: .image, bytes: 12 << 20, lastUnix: 0,
                 uses: UInt64($0 + 1), preview: "image")
        }
        let kept = Clips.retained(clips, now: now)
        #expect(kept.reduce(0) { $0 + $1.bytes } <= Clips.budget)
        #expect(kept.contains { $0.digest == "c9" })
        #expect(!kept.contains { $0.digest == "c0" })
    }

    @Test func clipQueryAndPreview() {
        func clip(_ id: String, _ preview: String, _ last: Int64) -> Clip {
            Clip(digest: id, kind: .text, bytes: preview.utf8.count, lastUnix: last, uses: 1, preview: preview)
        }
        let clips = [clip("a", "let value = 1", 10), clip("b", "SELECT * FROM users", 30), clip("c", "Let it be", 20)]
        #expect(Clips.query("", clips: clips).map(\.digest) == ["b", "c", "a"])
        #expect(Clips.query("let", clips: clips).map(\.digest) == ["c", "a"])
        #expect(Clips.query("   ", clips: clips).map(\.digest) == ["b", "c", "a"])
        #expect(Clips.query("zzz", clips: clips).isEmpty)
        #expect(Clips.preview("  let x = 1\n\n\tlet y = 2  ") == "let x = 1 let y = 2")
        #expect(Clips.preview(String(repeating: "x", count: Clips.previewLimit + 10)).count == Clips.previewLimit)
    }

    @MainActor @Test func clipStoreDropsBlobsWithEntries() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blobs = dir.appendingPathComponent("blobs")
        let clipboard = Clipboard(dir: dir)
        let later: Int64 = 5 * 86400
        clipboard.record(kind: .text, data: Data("stale".utf8), now: 0)
        clipboard.record(kind: .text, data: Data("reused".utf8), now: 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 2)
        let stale = try #require(clipboard.recent("stale", now: 0).first)
        let reused = try #require(clipboard.recent("reused", now: 0).first)

        clipboard.record(kind: .text, data: Data("reused".utf8), now: later - 60)
        #expect(clipboard.recent("reused", now: later).map(\.uses) == [1])
        #expect(!FileManager.default.fileExists(atPath: blobs.appendingPathComponent(stale.file).path))
        #expect(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(reused.file).path))
        #expect(clipboard.recent("", now: later).map(\.digest) == [reused.digest])

        let reloaded = Clipboard.load(dir: dir)
        #expect(reloaded.recent("reused", now: later).map(\.digest) == [reused.digest])
        Store.write(dir, "index.json", Data("{".utf8))
        #expect(Clipboard.load(dir: dir).recent("", now: later).isEmpty)
        #expect(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(reused.file).path))
        Store.write(dir, "index.json", Data("[]".utf8))
        try Data("orphan".utf8).write(to: blobs.appendingPathComponent("orphan.txt"))
        _ = Clipboard.load(dir: dir)
        #expect(!FileManager.default.fileExists(atPath: blobs.appendingPathComponent("orphan.txt").path))
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
