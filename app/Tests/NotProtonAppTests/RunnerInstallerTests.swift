import Foundation
import Testing

@testable import NotProtonApp

@Suite("Installing a runner from a release tarball")
struct RunnerInstallerTests {

    private func makeRunners() throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-point-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runners, withIntermediateDirectories: true)
        return runners
    }

    // A release holding only the files the install path checks and hashes, with the build
    // describing those exact bytes, so verification passes without a real 2G tree.
    private func makeSupportedArchive(
        in directory: URL, version: String = "11.18-aaaaaaaa", complete: Bool = true
    ) throws -> (WineArchive, RunnerBuild) {
        let fm = FileManager.default
        let tree = directory.appending(path: "tree")
        func write(_ path: String, _ text: String) throws {
            let file = tree.appending(path: path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try write("loader/wine", "wine loader \(version)")
        try write("server/wineserver", "wineserver")
        try write("loader/wine.inf", "inf")
        try write("dlls/ntdll/ntdll.so", "ntdll.so")
        if complete { try write("mnc-d3d/LAYOUT", "mnc-d3d pack layout: 2\n") }
        for arch in [WineArch.x86_64Windows, .i386Windows] {
            try write("dlls/ntdll/\(arch.rawValue)/ntdll.dll", "ntdll for \(arch.rawValue)")
        }

        func hash(_ path: String) throws -> String {
            try #require(Digest.sha256IfPresent(tree.appending(path: path)))
        }

        let build = RunnerBuild(
            bundleVersion: version,
            releaseVersion: "11.18",
            flavor: nil,
            loaderSHA256: try hash("loader/wine"),
            cleanNtdll: [
                .x86_64Windows: try hash("dlls/ntdll/x86_64-windows/ntdll.dll"),
                .i386Windows: try hash("dlls/ntdll/i386-windows/ntdll.dll"),
            ],
            patchedNtdll: [:]
        )

        let tarball = directory.appending(path: "source/wine-unified-osx64.tar.xz")
        try fm.createDirectory(at: tarball.deletingLastPathComponent(), withIntermediateDirectories: true)
        let packed = try Shell.run("/usr/bin/tar", [
            "-cJf", tarball.path(percentEncoded: false), "-C", tree.path(percentEncoded: false), ".",
        ])
        #expect(packed.status == 0)
        return (WineArchive(file: tarball, support: .supported(build)), build)
    }

    @Test("The tree lands inside the build directory where the run script looks for it")
    func treeLandsInsideBuildDirectory() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (archive, build) = try makeSupportedArchive(in: runners.appending(path: "src"))
        _ = try RunnerInstaller.clone(from: archive, runners: runners)

        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        #expect(root.path(percentEncoded: false).hasSuffix("/mnc-\(build.id)/wine"))
        #expect(FileManager.default.fileExists(atPath: RunnerLayout.loader(in: root).path(percentEncoded: false)))
        #expect(RunnerInstaller.hasClone(forBuild: build.id, runners: runners))
    }

    @Test("A tree that never finished unpacking is replaced rather than kept")
    func partialCloneIsReplaced() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (archive, build) = try makeSupportedArchive(in: runners.appending(path: "src"))

        let stale = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: stale.appending(path: "leftover"))
        #expect(!RunnerInstaller.hasClone(forBuild: build.id, runners: runners))

        _ = try RunnerInstaller.clone(from: archive, runners: runners)

        #expect(RunnerInstaller.hasClone(forBuild: build.id, runners: runners))
        #expect(!FileManager.default.fileExists(
            atPath: stale.appending(path: "leftover").path(percentEncoded: false)
        ))
    }

    @Test("Installing another build leaves the first one in place")
    func cloneKeepsOtherBuilds() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (first, firstBuild) = try makeSupportedArchive(
            in: runners.appending(path: "first"), version: "11.18-aaaaaaaa"
        )
        let (second, secondBuild) = try makeSupportedArchive(
            in: runners.appending(path: "second"), version: "11.19-bbbbbbbb"
        )

        _ = try RunnerInstaller.clone(from: first, runners: runners)
        _ = try RunnerInstaller.clone(from: second, runners: runners)
        #expect(RunnerInstaller.hasClone(forBuild: firstBuild.id, runners: runners))
        #expect(RunnerInstaller.hasClone(forBuild: secondBuild.id, runners: runners))
    }

    @Test("A tarball that is not a build tree is refused and leaves nothing behind")
    func incompleteTreeIsRefused() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (archive, build) = try makeSupportedArchive(in: runners.appending(path: "src"), complete: false)

        let failure = try #require(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: archive, runners: runners)
        }
        #expect(failure.detail.contains("mnc-d3d/LAYOUT"))
        let target = SupportPaths.runnerRoot(forBuild: build.id, runners: runners)
        let staging = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).new")
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }

    // Setup skips unpacking for a tree that is already there, so nothing else catches a loader
    // that went missing.
    @Test("A tree that lost its loader is refused")
    func refusesCloneThatLostItsLoader() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (archive, build) = try makeSupportedArchive(in: runners.appending(path: "src"))
        _ = try RunnerInstaller.clone(from: archive, runners: runners)

        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try Data("swapped".utf8).write(to: MncWineSource.unixLoader(inRoot: root))

        let failure = try #require(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: archive, runners: runners)
        }
        #expect(failure.detail.contains("does not match build"))
    }

    // Replacing an intact tree used to remove it first, so a failed unpack took a working
    // runner with it.
    @Test("A failed reinstall leaves the working tree intact")
    func keepsWorkingCloneWhenRecopyFails() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let (archive, build) = try makeSupportedArchive(in: runners.appending(path: "src"))
        _ = try RunnerInstaller.clone(from: archive, runners: runners)

        let loader = RunnerLayout.loader(in: SupportPaths.clonedRoot(forBuild: build.id, runners: runners))
        let files = FileManager.default
        #expect(files.fileExists(atPath: loader.path(percentEncoded: false)))

        try files.removeItem(at: archive.file)

        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: archive, replacingExisting: true, runners: runners)
        }

        #expect(
            files.fileExists(atPath: loader.path(percentEncoded: false)),
            "a reinstall that failed destroyed the working tree"
        )
    }

    @Test("A tarball NotProton does not know is refused before anything is unpacked")
    func unsupportedArchiveIsRefused() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }
        let archive = WineArchive(
            file: runners.appending(path: "wine-unified-osx64.tar.xz"), support: .unsupportedBuild("0123")
        )
        #expect(throws: StepFailure.self) { try RunnerInstaller.clone(from: archive, runners: runners) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: runners.path(percentEncoded: false)).isEmpty)
    }

    @Test("The state reader agrees with what was just written")
    func stateAgreesWithInstaller() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let version = SupportedRunners.all[0].bundleVersion
        try markClone(SupportPaths.clonedRoot(forBuild: version, runners: runners))

        #expect(RunnerStore.state(runners: runners, verify: { _, _ in [] })
            == .ready(builds: [version]))
    }
}
