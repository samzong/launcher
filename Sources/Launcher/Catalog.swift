import Foundation

enum Kind {
    case app
    case quit
}

struct Entry {
    var id: String
    var name: String
    var aliases: [String]
    var path: String
    var kind: Kind

    static let quit = Entry(id: "internal.quit", name: "Quit Launcher", aliases: ["quit"], path: "", kind: .quit)
}

func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

func lowercase(_ text: String) -> String {
    guard text.unicodeScalars.contains("Σ") else { return text.lowercased() }
    let scalars = Array(text.unicodeScalars)
    var result = ""
    var precededByCased = false
    for index in scalars.indices {
        let scalar = scalars[index]
        if scalar == "Σ" {
            let followedByCased = scalars[(index + 1)...].first { !$0.properties.isCaseIgnorable }?.properties.isCased == true
            result += precededByCased && !followedByCased ? "ς" : "σ"
        } else {
            result += String(scalar).lowercased()
        }
        if !scalar.properties.isCaseIgnorable {
            precededByCased = scalar.properties.isCased
        }
    }
    return result
}

func trim(_ text: String) -> String {
    var scalars = text.unicodeScalars[...]
    while scalars.first?.properties.isWhitespace == true {
        scalars.removeFirst()
    }
    while scalars.last?.properties.isWhitespace == true {
        scalars.removeLast()
    }
    return String(scalars)
}

func plainInteger(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number) else { return nil }
    return number
}

enum Catalog {
    static func scan(roots: [String]? = nil) -> [Entry] {
        var seen = Set<NSString>()
        var apps: [Entry] = []
        for root in roots ?? defaultRoots() {
            for path in bundles(in: root, depth: 0) {
                guard let entry = parse(path), seen.insert(entry.id as NSString).inserted else { continue }
                apps.append(entry)
            }
        }
        var sorted = apps.enumerated()
            .map { (key: Array(lowercase($0.element.name).utf8), order: $0.offset, entry: $0.element) }
            .sorted { $0.key == $1.key ? $0.order < $1.order : $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.entry)
        sorted.append(.quit)
        return sorted
    }

    static func parse(_ path: String) -> Entry? {
        let info = (path as NSString).appendingPathComponent("Contents/Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: info)),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              format != .xml || XMLParser(data: data).parse(), let dict = raw as? [String: Any]
        else { return nil }
        if let flag = dict["LSBackgroundOnly"], isTruthy(flag) {
            return nil
        }
        let stem = split((path as NSString).lastPathComponent).stem
        let names = [dict["CFBundleDisplayName"] as? String, dict["CFBundleName"] as? String, stem]
            .compactMap(\.self)
            .map(cleanName)
        guard let name = names.first else { return nil }
        var aliases: [String] = []
        for extra in names.dropFirst()
            where !sameBytes(extra, name) && !aliases.contains(where: { sameBytes($0, extra) })
        {
            aliases.append(extra)
        }
        let bundleID = dict["CFBundleIdentifier"] as? String
        return Entry(id: bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? path,
                     name: name,
                     aliases: aliases,
                     path: path,
                     kind: .app)
    }

    static func cleanName(_ name: String) -> String {
        for suffix in [".app", ".APP"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private static func defaultRoots() -> [String] {
        var roots: [String] = []
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            roots.append((home as NSString).appendingPathComponent("Applications"))
        }
        roots.append(contentsOf: ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications"])
        return roots
    }

    private static func bundles(in root: String, depth: Int) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [String] = []
        for name in names {
            let path = (root as NSString).appendingPathComponent(name)
            if split(name).ext == "app" {
                out.append(path)
                continue
            }
            var directory: ObjCBool = false
            if depth == 0, FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
                out.append(contentsOf: bundles(in: path, depth: 1))
            }
        }
        return out
    }

    private static func split(_ name: String) -> (stem: String, ext: String?) {
        guard name != "..", let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    private static func isTruthy(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return plainInteger(number).flatMap { Int64(exactly: $0) }.map { $0 != 0 } ?? false
        }
        if let text = value as? String {
            return ["1", "true", "YES", "yes"].contains(text)
        }
        return false
    }
}
