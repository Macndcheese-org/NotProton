// Finds MnC Wine release tarballs on disk, recognizes the build they carry, and
// unpacks them.

import Foundation
import Synchronization

enum ArchiveSupport: Sendable, Equatable {
    case supported(RunnerBuild)
    case unsupportedBuild(String)
    case unreadable
}

struct WineArchive: Sendable, Identifiable {
    let file: URL
    let support: ArchiveSupport

    // Selected by the user rather than found on disk by the tool.
    var isManual = false

    var id: String { file.path(percentEncoded: false) }
    var name: String { file.lastPathComponent }

    var isUsable: Bool {
        if case .supported = support { return true }
        return false
    }
}

enum MncWineSource {

    static let step = "Unpack MnC Wine"

    static var searchRoots: [URL] {
        [SupportPaths.defaultArchive.deletingLastPathComponent()]
    }

    static let releasePrefix = "wine-unified"
    static let releaseSuffix = ".tar.xz"

    private static let manualKey = "manualWineArchives"

    static func manualArchives(_ defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: manualKey) ?? [])
            .filter { !$0.isEmpty }.map { URL(filePath: $0) }
    }

    static func setManualArchives(_ archives: [URL], _ defaults: UserDefaults = .standard) {
        defaults.set(archives.map { $0.path(percentEncoded: false) }, forKey: manualKey)
    }

    static func addManualArchive(_ archive: URL, _ defaults: UserDefaults = .standard) {
        let current = manualArchives(defaults)
        guard !current.contains(where: { same($0, archive) }) else { return }
        setManualArchives(current + [archive], defaults)
    }

    static func removeManualArchive(_ archive: URL, _ defaults: UserDefaults = .standard) {
        setManualArchives(manualArchives(defaults).filter { !same($0, archive) }, defaults)
    }

    static func isSearched(_ archive: URL) -> Bool {
        let parent = archive.standardizedFileURL.deletingLastPathComponent()
        return searchRoots.contains { same($0, parent) } && isReleaseName(archive)
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path(percentEncoded: false) == b.standardizedFileURL.path(percentEncoded: false)
    }

    static func isReleaseName(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        return name.hasPrefix(releasePrefix) && name.hasSuffix(releaseSuffix)
    }

    // An xz stream starts with FD 37 7A 58 5A 00.
    static func looksLikeArchive(_ file: URL) -> Bool {
        guard file.lastPathComponent.hasSuffix(releaseSuffix),
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 6)) ?? Data()
        return magic == Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])
    }

    static func discover() -> [WineArchive] {
        let fm = FileManager.default
        var found: [WineArchive] = []
        var seen: Set<String> = []

        func consider(_ file: URL, isManual: Bool) {
            let key = file.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(key), looksLikeArchive(file) else { return }
            seen.insert(key)
            found.append(inspect(archive: file, isManual: isManual))
        }

        for manual in manualArchives() where !isSearched(manual) { consider(manual, isManual: true) }

        for root in searchRoots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where isReleaseName(entry) {
                consider(entry, isManual: false)
            }
        }

        return found.sorted(by: preferred)
    }

    static func preferred(_ a: WineArchive, _ b: WineArchive) -> Bool {
        if a.isManual != b.isManual { return a.isManual }
        if a.isUsable != b.isUsable { return a.isUsable }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    static func inspect(archive: URL, isManual: Bool = false) -> WineArchive {
        guard let hash = archiveDigest(archive) else {
            return WineArchive(file: archive, support: .unreadable, isManual: isManual)
        }
        guard let build = SupportedRunners.build(archiveSHA256: hash) else {
            return WineArchive(
                file: archive, support: .unsupportedBuild(String(hash.prefix(12))), isManual: isManual
            )
        }
        return WineArchive(file: archive, support: .supported(build), isManual: isManual)
    }

    // Hashing a release takes a second or two, so a refresh reuses the answer for a file
    // that has not changed since.
    private struct DigestKey: Hashable {
        let path: String
        let size: Int
        let modified: Date
    }

    private static let digests = Mutex<[DigestKey: String]>([:])

    static func archiveDigest(_ file: URL) -> String? {
        let path = file.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let key = DigestKey(path: path, size: size, modified: modified)
        if let known = digests.withLock({ $0[key] }) { return known }
        guard let hash = try? Digest.sha256(of: file) else { return nil }
        digests.withLock { $0[key] = hash }
        return hash
    }

    static func unixLoader(inRoot root: URL) -> URL {
        RunnerLayout.loader(in: root)
    }

    // Unpacks the release into `target`, which must not exist yet.
    static func unpack(_ archive: URL, to target: URL, tar: String = "/usr/bin/tar") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let result = try Shell.run(tar, [
            "-xJf", archive.path(percentEncoded: false), "-C", target.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: "Unpacking \(archive.lastPathComponent) failed. "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // The pieces the run script and the patcher reach for. A tree without them is a
    // different kind of tarball or a truncated download.
    static let requiredPaths = [
        RunnerLayout.loaderPath,
        RunnerLayout.wineserverPath,
        "dlls/ntdll/ntdll.so",
        "loader/wine.inf",
        "\(RunnerLayout.d3dPackPath)/LAYOUT",
    ]

    static func verifyTree(root: URL) throws {
        let fm = FileManager.default
        let missing = requiredPaths.filter {
            !fm.fileExists(atPath: root.appending(path: $0).path(percentEncoded: false))
        }
        guard missing.isEmpty else {
            throw StepFailure(
                step: step,
                detail: "This is not an MnC Wine build tree. Missing: \(missing.joined(separator: ", "))."
            )
        }
        let layout = (try? String(contentsOf: root.appending(path: "\(RunnerLayout.d3dPackPath)/LAYOUT"),
                                  encoding: .utf8)) ?? ""
        guard layout.contains("layout: 2") else {
            throw StepFailure(
                step: step,
                detail: "The bundled d3d pack is not layout 2, which this version of NotProton reads."
            )
        }
    }

    // Shown next to the installed build, e.g. "DXMT b3b93eed, GPTK 3.0 + 4.0b2".
    static func packVersion(root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appending(path: "\(RunnerLayout.d3dPackPath)/VERSION"),
                                     encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var parts: [String] = []
        if let dxmt = fields["dxmt"]?.split(separator: " ").dropFirst(2).first {
            parts.append("DXMT \(dxmt)")
        }
        let gptk = [fields["gptk3"], fields["gptk4"]].compactMap { $0 }
        if !gptk.isEmpty { parts.append("GPTK \(gptk.joined(separator: " + "))") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func verifyPatchInputs(root: URL, build: RunnerBuild) throws {
        for arch in WineArch.allCases {
            guard let expected = build.cleanNtdll[arch] else { continue }
            let ntdll = NtdllPatcher.cleanSource(inRoot: root, arch: arch)
            guard let actual = Digest.sha256IfPresent(ntdll) else {
                throw StepFailure(
                    step: "Verify MnC Wine",
                    detail: "\(arch.rawValue)/ntdll.dll is missing from \(root.path(percentEncoded: false))."
                )
            }
            guard actual == expected else {
                throw StepFailure(
                    step: "Verify MnC Wine",
                    detail: "\(arch.rawValue)/\(ntdll.lastPathComponent) is not the build "
                        + "\(build.bundleVersion) copy. Expected \(expected.prefix(16)), "
                        + "found \(actual.prefix(16))."
                )
            }
        }
    }
}
