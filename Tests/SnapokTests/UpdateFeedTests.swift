import Foundation

@main
struct UpdateFeedTests {
    static func main() {
        // Semantic versions, including prereleases.
        let ordered = ["0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.10", "1.0.0", "1.0.1", "1.2", "1.10.0"]
        for (index, lower) in ordered.enumerated() {
            for higher in ordered[(index + 1)...] {
                precondition(UpdateRelease.compare(lower, higher) == .orderedAscending, "\(lower) < \(higher)")
                precondition(UpdateRelease.compare(higher, lower) == .orderedDescending, "\(higher) > \(lower)")
            }
        }
        precondition(UpdateRelease.compare("1.2", "1.2.0") == .orderedSame)

        // The manifest written by scripts/publish-cdn.sh.
        let sha = String(repeating: "AB", count: 32)
        func manifest(version: String = "0.2.0", build: Int = 7, url: String = "https://cdn.snapok.app/Snapok-0.2.0.zip",
                      sha256: String = sha, minimum: String = "14.0") -> Data {
            try! JSONSerialization.data(withJSONObject: ["version": version, "build": build, "notes": "Fixes", "url": url,
                                                         "sha256": sha256, "dmg": "https://cdn.snapok.app/Snapok-0.2.0.dmg",
                                                         "minimumSystemVersion": minimum])
        }
        guard let release = UpdateRelease(json: manifest()) else { fatalError("valid manifest rejected") }
        precondition(release.version == "0.2.0" && release.build == 7 && release.notes == "Fixes")
        precondition(release.sha256 == sha.lowercased(), "checksums are compared in lowercase")
        precondition(UpdateRelease(json: manifest(url: "http://cdn.snapok.app/x.zip")) == nil, "plain HTTP is refused")
        precondition(UpdateRelease(json: manifest(sha256: "abc")) == nil, "a malformed checksum is refused")
        precondition(UpdateRelease(json: Data("{}".utf8)) == nil && UpdateRelease(json: Data("oops".utf8)) == nil)

        // Newer version, or the same version with a newer build (development builds share a version).
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        precondition(release.isNewer(thanVersion: "0.1.0", build: 99, system: sonoma))
        precondition(release.isNewer(thanVersion: "0.2.0", build: 6, system: sonoma))
        precondition(!release.isNewer(thanVersion: "0.2.0", build: 7, system: sonoma))
        precondition(!release.isNewer(thanVersion: "0.3.0", build: 1, system: sonoma))
        precondition(release.isNewer(thanVersion: "0.2.0-beta.1", build: 99, system: sonoma), "a release beats its prereleases")
        let needsNewerSystem = UpdateRelease(json: manifest(minimum: "15.1"))!
        precondition(!needsNewerSystem.isNewer(thanVersion: "0.1.0", build: 1, system: sonoma), "skips builds this macOS can't run")
        precondition(needsNewerSystem.isNewer(thanVersion: "0.1.0", build: 1,
                                              system: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)))
        print("Passed update feed checks: version order, manifest parsing, build and system requirements")
    }
}
