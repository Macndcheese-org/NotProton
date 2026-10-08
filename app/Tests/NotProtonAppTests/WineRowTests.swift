import Foundation
import Testing

@testable import NotProtonApp

@Suite("MnC Wine rows on the Status pane")
struct WineRowTests {

    private static let current = SupportedRunners.all[0]
    private static let next = RunnerBuild(
        bundleVersion: "11.19-bbbbbbbb", releaseVersion: "11.19", flavor: nil,
        loaderSHA256: "", cleanNtdll: [:], patchedNtdll: [:]
    )

    private func archive(_ name: String, _ build: RunnerBuild, root: String = "/Users/me/Downloads") -> WineArchive {
        WineArchive(file: URL(filePath: "\(root)/\(name)"), support: .supported(build))
    }

    private func rows(
        _ archives: [WineArchive],
        installed: [RunnerBuild] = [],
        damaged: [String] = [],
        orphaned: [String] = [],
        unpatched: [String] = []
    ) -> [WineRow] {
        WineRow.rows(
            archives: archives, installed: installed,
            damaged: damaged, orphaned: orphaned, unpatched: unpatched
        )
    }

    @Test("Each tarball gets its own row, tied to its own build")
    func oneRowPerArchive() {
        let next = archive("wine-unified-next.tar.xz", Self.next)
        let current = archive("wine-unified-osx64.tar.xz", Self.current)

        let made = rows([next, current], installed: [Self.next, Self.current])

        #expect(made.map(\.archive?.id) == [next.id, current.id])
        #expect(made.map(\.buildID) == [Self.next.id, Self.current.id])
        #expect(made.allSatisfy { $0.copy == .ready && $0.canSetUp })
    }

    @Test("A tarball with no copy yet can be set up and is named after the file")
    func archiveWithoutCopy() {
        let current = archive("wine-unified-osx64.tar.xz", Self.current)

        let made = rows([current])

        #expect(made.count == 1)
        #expect(made[0].copy == .none)
        #expect(made[0].canSetUp)
        #expect(made[0].title == "wine-unified-osx64.tar.xz")
    }

    @Test("A copy whose tarball is gone keeps a row that cannot be unpacked again")
    func copyWithoutArchive() {
        let made = rows([], installed: [Self.current])

        #expect(made.count == 1)
        #expect(made[0].archive == nil)
        #expect(made[0].copy == .ready)
        #expect(!made[0].canSetUp)
        #expect(made[0].title == Self.current.displayVersion)
    }

    @Test("Damaged, unpatched and unsupported copies are marked on their own rows")
    func problemCopies() {
        let next = archive("wine-unified-next.tar.xz", Self.next)
        let current = archive("wine-unified-osx64.tar.xz", Self.current)

        let made = rows(
            [next, current], installed: [Self.next], damaged: [Self.current.id],
            orphaned: ["11.0-00000000"], unpatched: [Self.next.id]
        )

        #expect(made.map(\.copy) == [.unpatched, .damaged, .unsupported])
        #expect(made[2].buildID == "11.0-00000000")
        #expect(made[2].archive == nil)
    }

    @Test("Two tarballs of the same build share one row, the preferred one")
    func sameBuildTwice() {
        let first = archive("wine-unified-osx64.tar.xz", Self.current)
        let second = archive("wine-unified-osx64.tar.xz", Self.current, root: "/Volumes/Spare")

        let made = rows([first, second], installed: [Self.current])

        #expect(made.map(\.archive?.id) == [first.id])
    }

    @Test("A picked tarball is found under the row for its path or its build")
    func pickedArchiveListing() {
        let first = archive("wine-unified-osx64.tar.xz", Self.current)
        let second = archive("wine-unified-osx64.tar.xz", Self.current, root: "/Volumes/Spare")
        let next = archive("wine-unified-next.tar.xz", Self.next, root: "/Volumes/Spare")

        let made = rows([first], installed: [Self.current, Self.next])

        #expect(WineRow.listing(first, in: made)?.id == first.id)
        #expect(WineRow.listing(second, in: made)?.id == first.id)
        #expect(WineRow.listing(next, in: made) == nil)

        let unknown = WineArchive(
            file: URL(filePath: "/Users/me/Downloads/wine-unified-old.tar.xz"),
            support: .unsupportedBuild("0123456789ab")
        )
        #expect(WineRow.listing(unknown, in: rows([unknown]))?.id == unknown.id)
        #expect(WineRow.listing(unknown, in: made) == nil)
    }

    @Test("A tarball NotProton doesn't know is listed with its hash and nothing to set up")
    func unsupportedArchive() {
        let unknown = WineArchive(
            file: URL(filePath: "/Users/me/Downloads/wine-unified-old.tar.xz"),
            support: .unsupportedBuild("0123456789ab")
        )

        let made = rows([unknown])

        #expect(made.count == 1)
        #expect(made[0].unsupportedHash == "0123456789ab")
        #expect(!made[0].canSetUp)
    }
}

@Suite("Manually added MnC Wine tarballs")
struct ManualWineArchiveTests {

    private func defaults() -> UserDefaults {
        let name = "np-manual-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Adding keeps earlier tarballs, skips repeats, and removing drops only the one named")
    func addAndRemove() {
        let defaults = defaults()
        let spare = URL(filePath: "/Volumes/Spare/wine-unified-osx64.tar.xz")
        let other = URL(filePath: "/Volumes/Other/wine-unified-next.tar.xz")

        MncWineSource.addManualArchive(spare, defaults)
        MncWineSource.addManualArchive(other, defaults)
        MncWineSource.addManualArchive(spare, defaults)
        #expect(MncWineSource.manualArchives(defaults) == [spare, other])

        MncWineSource.removeManualArchive(spare, defaults)
        #expect(MncWineSource.manualArchives(defaults) == [other])
    }

    @Test("A remembered release in Downloads is not treated as added by hand")
    func searchedFolderIsNotManual() {
        let downloads = SupportPaths.defaultArchive.deletingLastPathComponent()
        #expect(MncWineSource.isSearched(downloads.appending(path: "wine-unified-osx64.tar.xz")))
        #expect(!MncWineSource.isSearched(downloads.appending(path: "other.tar.xz")))
        #expect(!MncWineSource.isSearched(URL(filePath: "/Volumes/Spare/wine-unified-osx64.tar.xz")))
    }
}
