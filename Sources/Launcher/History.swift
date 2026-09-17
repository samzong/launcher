import Foundation

enum Store {
    static func dataDir() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        guard !home.isEmpty else { return URL(fileURLWithPath: "Launcher") }
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Launcher")
    }

    static func read(_ dir: URL, _ name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func hidden(_ dir: URL = dataDir()) -> Set<NSString> {
        guard let data = read(dir, "hidden.json"),
              let ids = (try? JSONSerialization.jsonObject(with: data)) as? [String]
        else { return [] }
        return Set(ids.map { $0 as NSString })
    }

    static func write(_ dir: URL, _ name: String, _ data: Data) {
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }
        let path = dir.appendingPathComponent(name)
        let tmp = path.deletingPathExtension().appendingPathExtension("json.tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        _ = rename(tmp.path, path.path)
    }
}

final class History {
    private struct Usage {
        var count: UInt64
        var lastUnix: Int64
    }

    private static let aliasFile = "aliases.json"
    private static let usageFile = "usage.json"
    private static let halfLifeDays = 14.0

    private let dataDir: URL?
    private var aliasMap: [NSString: String] = [:]
    private var usageMap: [NSString: Usage] = [:]

    init(dataDir: URL? = nil) {
        self.dataDir = dataDir
    }

    static func load(dataDir: URL = Store.dataDir()) -> History {
        let history = History(dataDir: dataDir)
        if let stored = object(dataDir, aliasFile) {
            var map: [NSString: String] = [:]
            for (key, value) in stored {
                guard let key = key as? NSString, let value = value as? String else {
                    map = [:]
                    break
                }
                map[key] = value
            }
            history.aliasMap = map
        }
        if let stored = object(dataDir, usageFile), let apps = stored["apps"] as? NSDictionary {
            var map: [NSString: Usage] = [:]
            for (key, value) in apps {
                guard let key = key as? NSString, let entry = value as? NSDictionary,
                      let count = plainInteger(entry["count"]).flatMap({ UInt64(exactly: $0) }),
                      let last = plainInteger(entry["last_unix"]).flatMap({ Int64(exactly: $0) })
                else {
                    map = [:]
                    break
                }
                map[key] = Usage(count: count, lastUnix: last)
            }
            history.usageMap = map
        }
        return history
    }

    private static func object(_ dir: URL, _ name: String) -> NSDictionary? {
        guard let data = Store.read(dir, name),
              let parsed = literalJSON(data)
        else { return nil }
        return parsed as? NSDictionary
    }

    private static func literalJSON(_ data: Data) -> Any? {
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else { return nil }
        var protected: [UInt8] = []
        var quoted = false
        var escaped = false
        for byte in data {
            protected.append(byte)
            if escaped {
                escaped = false
            } else if quoted, byte == 92 {
                escaped = true
            } else if byte == 34 {
                quoted.toggle()
                if quoted {
                    protected.append(32)
                }
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(protected)) else { return nil }
        func restore(_ value: Any) -> Any {
            if let string = value as? NSString {
                return string.substring(from: 1) as NSString
            }
            guard let dictionary = value as? NSDictionary else { return value }
            let restored = NSMutableDictionary()
            for (key, value) in dictionary {
                restored[(key as! NSString).substring(from: 1) as NSString] = restore(value)
            }
            return restored
        }
        return restore(object)
    }

    func record(_ query: String, id: String) {
        if remember(query, id: id) {
            persist(Self.aliasFile, aliasObject())
        }
        recordAt(id, now: Int64(max(0, Date().timeIntervalSince1970)))
        persist(Self.usageFile, usageObject())
    }

    @discardableResult
    func remember(_ query: String, id: String) -> Bool {
        let key = lowercase(trim(query))
        guard !key.isEmpty else { return false }
        aliasMap[key as NSString] = id
        return true
    }

    func recordAt(_ id: String, now: Int64) {
        var entry = usageMap[id as NSString] ?? Usage(count: 0, lastUnix: now)
        entry.count &+= 1
        entry.lastUnix = now
        usageMap[id as NSString] = entry
    }

    func score(_ id: String, now: Int64) -> Double {
        guard let entry = usageMap[id as NSString] else { return 0 }
        let days = max(Double(now &- entry.lastUnix) / 86400, 0)
        return log(1 + Double(entry.count)) * exp(-days / Self.halfLifeDays)
    }

    func aliasesFor(_ id: String) -> [String] {
        aliasMap.compactMap { sameBytes($0.value, id) ? $0.key as String : nil }
    }

    private func persist(_ name: String, _ stored: NSDictionary) {
        guard let dataDir,
              let data = try? JSONSerialization.data(withJSONObject: stored,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        Store.write(dataDir, name, data)
    }

    private func aliasObject() -> NSDictionary {
        let stored = NSMutableDictionary()
        for (key, value) in aliasMap {
            stored[key] = value
        }
        return stored
    }

    private func usageObject() -> NSDictionary {
        let entries = NSMutableDictionary()
        for (key, value) in usageMap {
            entries[key] = ["count": value.count, "last_unix": value.lastUnix] as NSDictionary
        }
        return ["apps": entries] as NSDictionary
    }
}
