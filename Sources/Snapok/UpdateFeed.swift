import Foundation

/// The manifest published by `scripts/publish-cdn.sh`: https://cdn.snapok.app/latest.json for Snapok,
/// https://cdn.snapok.app/dev/latest.json for Snapok Dev.
struct UpdateRelease: Equatable, Sendable {
    let version: String
    let build: Int
    let notes: String
    /// Notarized ZIP of the app, installed in place.
    let url: URL
    /// Lowercase hex SHA-256 of the ZIP.
    let sha256: String
    /// The same build as a DMG, for a manual download.
    let dmg: URL?
    let minimumSystemVersion: String?

    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty,
              let url = (object["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https",
              let sha256 = (object["sha256"] as? String)?.lowercased(), sha256.count == 64 else { return nil }
        self.version = version
        build = object["build"] as? Int ?? 0
        notes = object["notes"] as? String ?? ""
        self.url = url
        self.sha256 = sha256
        dmg = (object["dmg"] as? String).flatMap(URL.init(string:))
        minimumSystemVersion = object["minimumSystemVersion"] as? String
    }

    /// Newer than the running version and build, and installable on this macOS.
    func isNewer(thanVersion version: String, build: Int,
                 system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        if let minimum = minimumSystemVersion {
            let system = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
            if UpdateRelease.compare(minimum, system) == .orderedDescending { return false }
        }
        switch UpdateRelease.compare(self.version, version) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: return self.build > build
        }
    }

    /// Semantic version order: 1.2.10 > 1.2.9, and 1.2.0 > 1.2.0-beta.2 > 1.2.0-beta.1.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ version: String) -> ([Int], [String]?) {
            let parts = version.split(separator: "-", maxSplits: 1).map(String.init)
            let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (numbers, parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : nil)
        }
        let (numbersA, preA) = split(a), (numbersB, preB) = split(b)
        for index in 0..<max(numbersA.count, numbersB.count) {
            let x = index < numbersA.count ? numbersA[index] : 0, y = index < numbersB.count ? numbersB[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (preA, preB) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (x?, y?):
            for index in 0..<max(x.count, y.count) {
                guard index < x.count else { return .orderedAscending }
                guard index < y.count else { return .orderedDescending }
                let order: ComparisonResult
                switch (Int(x[index]), Int(y[index])) {
                case let (m?, n?): order = m == n ? .orderedSame : (m < n ? .orderedAscending : .orderedDescending)
                case (_?, nil): order = .orderedAscending
                case (nil, _?): order = .orderedDescending
                case (nil, nil): order = x[index].compare(y[index])
                }
                if order != .orderedSame { return order }
            }
            return .orderedSame
        }
    }
}
