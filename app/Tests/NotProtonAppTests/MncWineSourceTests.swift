import Foundation
import Testing

@testable import NotProtonApp

@Suite("Finding and unpacking MnC Wine releases")
struct MncWineSourceTests {

    private func archive(
        _ name: String, _ support: ArchiveSupport,
        root: String = "/Users/me/Downloads", isManual: Bool = false
    ) -> WineArchive {
        WineArchive(file: URL(filePath: "\(root)/\(name)"), support: support, isManual: isManual)
    }

    private func picked(_ archives: [WineArchive]) -> WineArchive? {
        archives.sorted(by: MncWineSource.preferred).first(where: \.isUsable)
    }

    private func scratch() throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "notproton-mnc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A usable tarball is chosen over one NotProton does not know")
    func skipsUnknownArchive() {
        let build = SupportedRunners.all[0]
        let unknown = archive("wine-unified-a.tar.xz", .unsupportedBuild("0123"))
        let known = archive("wine-unified-b.tar.xz", .supported(build))

        #expect(picked([unknown, known])?.name == "wine-unified-b.tar.xz")
        #expect(picked([known, unknown])?.name == "wine-unified-b.tar.xz")
    }

    @Test("With no usable tarball, nothing is chosen")
    func nonePickedWhenAllUnusable() {
        let unknown = archive("wine-unified-a.tar.xz", .unsupportedBuild("0123"))
        let unreadable = archive("wine-unified-b.tar.xz", .unreadable)
        #expect(picked([unknown, unreadable]) == nil)
    }

    @Test("A tarball the user named is taken over one the search found")
    func prefersNamedArchive() {
        let build = SupportedRunners.all[0]
        let found = archive("wine-unified-osx64.tar.xz", .supported(build))
        let named = archive("wine-unified-osx64.tar.xz", .supported(build), root: "/Volumes/Spare", isManual: true)

        #expect(picked([found, named])?.isManual == true)
        #expect(picked([named, found])?.isManual == true)
    }

    @Test("The same build in two folders resolves to the same one every sort")
    func breaksNameTieByPath() {
        let build = SupportedRunners.all[0]
        let a = archive("wine-unified-osx64.tar.xz", .supported(build), root: "/A")
        let b = archive("wine-unified-osx64.tar.xz", .supported(build), root: "/B")

        #expect(picked([a, b])?.id == a.id)
        #expect(picked([b, a])?.id == a.id)
    }

    @Test("A file that is not a known release is refused with its hash, and a missing one is unreadable")
    func unknownArchiveIsUnsupported() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "wine-unified-osx64.tar.xz")
        try Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 1, 2, 3]).write(to: file)

        let hash = try Digest.sha256(of: file)
        #expect(MncWineSource.inspect(archive: file).support == .unsupportedBuild(String(hash.prefix(12))))
        #expect(MncWineSource.inspect(archive: dir.appending(path: "gone.tar.xz")).support == .unreadable)
    }

    @Test("Only an xz stream with the release suffix looks like a release")
    func archiveMagic() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xz = dir.appending(path: "wine-unified-osx64.tar.xz")
        let text = dir.appending(path: "notes.tar.xz")
        let named = dir.appending(path: "wine-unified-osx64.zip")
        try Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]).write(to: xz)
        try Data("hello".utf8).write(to: text)
        try Data([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]).write(to: named)

        #expect(MncWineSource.looksLikeArchive(xz))
        #expect(!MncWineSource.looksLikeArchive(text))
        #expect(!MncWineSource.looksLikeArchive(named))
    }

    @Test("A tree missing what the run script reaches for is refused, and a complete one passes")
    func treeVerification() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        #expect(throws: StepFailure.self) { try MncWineSource.verifyTree(root: dir) }

        for path in MncWineSource.requiredPaths {
            let file = dir.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("layout: 2\n".utf8).write(to: file)
        }
        try MncWineSource.verifyTree(root: dir)

        try Data("layout: 1\n".utf8).write(to: dir.appending(path: "mnc-d3d/LAYOUT"))
        #expect(throws: StepFailure.self) { try MncWineSource.verifyTree(root: dir) }
    }

    @Test("The pack version names DXMT and both toolkits")
    func packVersion() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "mnc-d3d"), withIntermediateDirectories: true)
        try Data("""
            layout: 2
            built: 2026-09-01T08:16:26Z
            gptk3: 3.0
            gptk4: 4.0b2
            dxmt: Macndcheese-org/dxmt mncDXMT b3b93eed (built 2026-09-26T16:58:53Z against wine 11.18)
            """.utf8).write(to: dir.appending(path: "mnc-d3d/VERSION"))

        #expect(MncWineSource.packVersion(root: dir) == "DXMT b3b93eed, GPTK 3.0 + 4.0b2")
    }

    @Test("Unpacking puts the tarball's tree where it was asked to")
    func unpacksTree() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "src")
        try FileManager.default.createDirectory(at: source.appending(path: "loader"), withIntermediateDirectories: true)
        try Data("loader".utf8).write(to: source.appending(path: "loader/wine"))
        let tarball = dir.appending(path: "wine-unified-osx64.tar.xz")
        let packed = try Shell.run("/usr/bin/tar", [
            "-cJf", tarball.path(percentEncoded: false), "-C", source.path(percentEncoded: false), ".",
        ])
        #expect(packed.status == 0)

        let target = dir.appending(path: "out/wine")
        try MncWineSource.unpack(tarball, to: target)
        #expect(try String(contentsOf: target.appending(path: "loader/wine"), encoding: .utf8) == "loader")
    }
}
