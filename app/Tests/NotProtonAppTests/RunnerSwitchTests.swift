import Foundation
import Testing

@testable import NotProtonApp

@Suite("Preparing an installed build")
struct RunnerPrepareTests {

    private static let current = SupportedRunners.all[0]
    // A clone NotProton no longer supports, which still sits in runners/.
    private static let orphan = "11.0-00000000"

    private static let runScript = Data("#!/bin/sh\n".utf8)

    private final class Calls: @unchecked Sendable {
        var staged: [String] = []
        var patched: [String] = []
    }

    private func makeRunners(cloning builds: [RunnerBuild]) throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-prepare-\(UUID().uuidString)")
        for build in builds {
            try markClone(SupportPaths.clonedRoot(forBuild: build.id, runners: runners))
        }
        return runners
    }

    private static func writeStaged(for build: RunnerBuild, into bridge: URL) throws {
        for arch in build.patchedNtdll.keys {
            try atomicReplace(
                NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge),
                with: Data("\(build.id) \(arch.rawValue)".utf8), step: "test"
            )
        }
    }

    private static func staged(_ build: RunnerBuild, in bridge: URL) -> [WineArch: Data] {
        var found: [WineArch: Data] = [:]
        for arch in WineArch.allCases {
            let copy = NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)
            if let data = try? Data(contentsOf: copy) { found[arch] = data }
        }
        return found
    }

    private func prepare(
        _ build: RunnerBuild,
        runners: URL,
        calls: Calls,
        failPatch: Bool = false
    ) throws -> RunnerSetup.Outcome {
        try RunnerSetup.prepare(
            build,
            runners: runners,
            bridge: runners.appending(path: "bridge"),
            toolList: runners.appending(path: "tools"),
            compatTools: runners.appending(path: "compatibilitytools.d"),
            runScript: {
                let script = runners.appending(path: "payload-run")
                try Self.runScript.write(to: script)
                return script
            },
            verify: { _, _ in },
            stage: { build, _, bridge in
                calls.staged.append(build.id)
                try Self.writeStaged(for: build, into: bridge)
                return []
            },
            patch: { build, _, _ in
                calls.patched.append(build.id)
                if failPatch { throw StepFailure(step: "test", detail: "patch failed") }
                return RunnerPatcher.Outcome()
            }
        )
    }

    private func toolList(_ runners: URL) -> String? {
        try? String(contentsOf: runners.appending(path: "tools"), encoding: .utf8)
    }

    @Test("The set-up build is listed as its tool")
    func listsTheBuild() throws {
        let runners = try makeRunners(cloning: [Self.current])
        defer { try? FileManager.default.removeItem(at: runners) }

        let calls = Calls()
        let outcome = try prepare(Self.current, runners: runners, calls: calls)

        #expect(outcome.toolsChanged)
        #expect(calls.staged == [Self.current.id])
        #expect(calls.patched == [Self.current.id])
        #expect(toolList(runners) == CompatToolList.contents(SupportedRunners.tools(for: [Self.current])))
        #expect(toolList(runners)?.hasPrefix("notproton-mnc\t\(Self.current.id)\trosetta\t") == true)

        let again = try prepare(Self.current, runners: runners, calls: calls)
        #expect(!again.toolsChanged)
    }

    @Test("Every listed tool gets a run script")
    func writesMissingRunScripts() throws {
        let runners = try makeRunners(cloning: [Self.current])
        defer { try? FileManager.default.removeItem(at: runners) }

        _ = try prepare(Self.current, runners: runners, calls: Calls())

        let tools = CompatToolList.installed(runners: runners, file: runners.appending(path: "tools"))
        #expect(!tools.isEmpty)
        for tool in tools {
            let run = runners.appending(path: "compatibilitytools.d/\(tool.name)/run")
            #expect(try Data(contentsOf: run) == Self.runScript)
            #expect(FileManager.default.isExecutableFile(atPath: run.path))
        }
    }

    @Test("A tool's existing run script is left alone")
    func keepsExistingRunScript() throws {
        let runners = try makeRunners(cloning: [Self.current])
        defer { try? FileManager.default.removeItem(at: runners) }
        let tool = SupportedRunners.tools(for: [Self.current])[0].name
        let run = runners.appending(path: "compatibilitytools.d/\(tool)/run")
        let old = Data("#!/bin/sh\nexec old\n".utf8)
        try atomicReplace(run, with: old, step: "test")

        _ = try prepare(Self.current, runners: runners, calls: Calls())

        #expect(try Data(contentsOf: run) == old)
    }

    @Test("A failed patch leaves the tool list as it was")
    func failedPatchKeepsList() throws {
        let runners = try makeRunners(cloning: [Self.current])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(throws: StepFailure.self) {
            try prepare(Self.current, runners: runners, calls: Calls(), failPatch: true)
        }
        #expect(toolList(runners) == nil)
    }

    @Test("Staged copies of builds no longer set up are cleared")
    func clearsGoneBuildsStaged() throws {
        let runners = try makeRunners(cloning: [Self.current])
        defer { try? FileManager.default.removeItem(at: runners) }
        let bridge = runners.appending(path: "bridge")
        let legacy = bridge.appending(path: "wine/x86_64-windows/ntdll.dll")
        let gone = NtdllPatcher.stagedCopy(of: .x86_64Windows, build: Self.orphan, in: bridge)
        for file in [legacy, gone] {
            try atomicReplace(file, with: Data("old".utf8), step: "test")
        }

        _ = try prepare(Self.current, runners: runners, calls: Calls())

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: legacy.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: gone.path(percentEncoded: false)))
        #expect(Self.staged(Self.current, in: bridge).count == Self.current.patchedNtdll.count)
    }

    @Test("With nothing set up and no list yet, no list is written")
    func writesNoEmptyList() throws {
        let runners = try makeRunners(cloning: [])
        defer { try? FileManager.default.removeItem(at: runners) }
        let file = runners.appending(path: "support/tools")

        let changed = try CompatToolList.sync(
            runners: runners, bridge: runners.appending(path: "bridge"), file: file,
            compatTools: runners.appending(path: "compatibilitytools.d")
        )

        #expect(!changed)
        #expect(!FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("No MnC Wine build takes the 1.0 'notproton' name")
    func noLegacyName() throws {
        let runners = try makeRunners(cloning: [Self.current])
        defer { try? FileManager.default.removeItem(at: runners) }
        try FileManager.default.createSymbolicLink(
            atPath: runners.appending(path: "current").path(percentEncoded: false),
            withDestinationPath: "mnc-\(Self.current.id)/wine"
        )

        try CompatToolList.sync(
            runners: runners, bridge: runners.appending(path: "bridge"), file: runners.appending(path: "tools"),
            compatTools: runners.appending(path: "compatibilitytools.d")
        )
        let names = toolList(runners)?.split(separator: "\n").map { $0.split(separator: "\t")[0] } ?? []
        #expect(names == ["notproton-mnc"])
    }

    @Test("A build with no clone is refused without touching anything")
    func refusesMissingClone() throws {
        let runners = try makeRunners(cloning: [])
        defer { try? FileManager.default.removeItem(at: runners) }

        let calls = Calls()
        let failure = try #require(throws: StepFailure.self) {
            try prepare(Self.current, runners: runners, calls: calls)
        }

        #expect(failure.detail.contains("has not been set up"))
        #expect(calls.staged.isEmpty)
        #expect(toolList(runners) == nil)
    }

    @Test("Installed builds are supported clones that still have their loader")
    func installedBuildsListing() throws {
        let runners = try makeRunners(cloning: [Self.current])
        defer { try? FileManager.default.removeItem(at: runners) }

        try markClone(SupportPaths.clonedRoot(forBuild: Self.orphan, runners: runners))

        #expect(RunnerStore.installedBuilds(in: runners) == [Self.current])
        try FileManager.default.removeItem(
            at: RunnerLayout.loader(in: SupportPaths.clonedRoot(forBuild: Self.current.id, runners: runners))
        )
        #expect(RunnerStore.installedBuilds(in: runners).isEmpty)
    }
}

@MainActor
@Suite("Choosing which tarball to set up from")
struct SetupSourceTests {

    private static let current = SupportedRunners.all[0]
    private static let next = RunnerBuild(
        bundleVersion: "11.19-bbbbbbbb", releaseVersion: "11.19", flavor: nil,
        loaderSHA256: "", cleanNtdll: [:], patchedNtdll: [:]
    )

    private func archive(_ name: String, _ build: RunnerBuild) -> WineArchive {
        WineArchive(file: URL(filePath: "/Users/me/Downloads/\(name)"), support: .supported(build))
    }

    private func status(runner: RunnerState, archives: [WineArchive]) -> SystemStatus {
        let status = SystemStatus()
        status.snapshot = StatusSnapshot(
            steam: .steamMissing,
            steamRunning: false,
            updateBlocked: false,
            archives: archives,
            runner: runner,
            payload: PayloadInspector.inspect(bridge: FileManager.default.temporaryDirectory, builds: [])
        )
        return status
    }

    @Test("A reinstall comes from the tarball a set-up build was unpacked from")
    func prefersInstalledBuild() {
        let current = archive("wine-unified-a.tar.xz", Self.current)
        let next = archive("wine-unified-b.tar.xz", Self.next)

        let status = status(runner: .ready(builds: [Self.next.id]), archives: [current, next])

        #expect(status.setupSource?.id == next.id)
    }

    @Test("With no tool set up, the preferred tarball is used")
    func fallsBackToPreferred() {
        let current = archive("wine-unified-a.tar.xz", Self.current)
        let next = archive("wine-unified-b.tar.xz", Self.next)

        let status = status(runner: .none, archives: [current, next])

        #expect(status.setupSource?.id == current.id)
        #expect(status.usableArchives.map(\.id) == [current.id, next.id])
    }

    @Test("A tarball of another build cannot repair a set-up one")
    func repairSourceIsNilWhenBuildDiffers() {
        let current = archive("wine-unified-a.tar.xz", Self.current)
        let status = status(runner: .ready(builds: [Self.next.id]), archives: [current])

        #expect(status.repairSource == nil)
        #expect(status.setupSource?.id == current.id)
    }

    @Test("With nothing set up there is no repair source")
    func noRepairSourceBeforeFirstSetUp() {
        let current = archive("wine-unified-a.tar.xz", Self.current)
        let status = status(runner: .none, archives: [current])

        #expect(status.repairSource == nil)
        #expect(status.setupSource?.id == current.id)
    }
}

@Suite("Removing an installed build")
struct RunnerRemovalTests {

    // The supported build, and a clone of one NotProton no longer knows.
    private static let rosetta = SupportedRunners.all[0]
    private static let fexID = "11.0-00000000"

    private func makeRunners(cloning builds: [String]) throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-remove-\(UUID().uuidString)")
        for build in builds {
            try markClone(SupportPaths.clonedRoot(forBuild: build, runners: runners))
        }
        return runners
    }

    private func remove(
        _ build: String, runners: URL, libraries: [SteamLibrary] = [], running: Bool = false
    ) throws -> Bool {
        try RunnerInstaller.removeClone(
            forBuild: build, runners: runners,
            bridge: runners.appending(path: "bridge"), toolList: runners.appending(path: "tools"),
            compatTools: runners.appending(path: "compatibilitytools.d"),
            libraries: libraries,
            running: { _ in running }
        )
    }

    @Test("Removing a build leaves nothing of it in the runners folder")
    func removalLeavesNothing() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fexID])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let leftover = runners.appending(path: ".mnc-\(Self.rosetta.id).removing/wine")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)

        _ = try remove(Self.rosetta.id, runners: runners)

        let left = try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.contains(Self.rosetta.id) }
        #expect(left.isEmpty)
        #expect(RunnerStore.clonedBuilds(in: runners) == [Self.fexID])
    }

    @Test("Removing a build also clears what an earlier failed removal of another build left")
    func removalClearsOtherLeftovers() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let leftover = runners.appending(path: ".mnc-\(Self.fexID).removing/wine")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)

        _ = try remove(Self.rosetta.id, runners: runners)

        #expect(try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.hasSuffix(".removing") }.isEmpty)
    }

    @Test("A removal whose tool list cannot be written puts the build back")
    func failedSyncRestoresBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fexID])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        // A list the removal has to rewrite, held so the rewrite fails.
        let list = runners.appending(path: "tools")
        try Data("stale\n".utf8).write(to: list)
        try fm.setAttributes([.immutable: true], ofItemAtPath: list.path(percentEncoded: false))
        defer { try? fm.setAttributes([.immutable: false], ofItemAtPath: list.path(percentEncoded: false)) }
        let staged = runners.appending(path: "bridge/wine/\(Self.rosetta.id)/x86_64-windows/ntdll.dll")
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("patched".utf8).write(to: staged)

        #expect(throws: (any Error).self) { try remove(Self.rosetta.id, runners: runners) }
        #expect(fm.fileExists(atPath: staged.path(percentEncoded: false)))

        #expect(RunnerStore.clonedBuilds(in: runners) == [Self.fexID, Self.rosetta.id].sorted())
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
        #expect(try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.hasSuffix(".removing") }.isEmpty)
    }

    @Test("Removing a build deletes its prefix templates in every library and keeps the others")
    func removesThatBuildsTemplates() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fexID])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let libraries = ["internal", "external"].map {
            SteamLibrary(root: runners.appending(path: "libraries/\($0)"))
        }
        for library in libraries {
            for build in [Self.rosetta.id, Self.fexID] {
                for template in SupportPaths.prefixTemplates(forBuild: build, in: library) {
                    try fm.createDirectory(
                        at: template.appending(path: "pfx/drive_c"), withIntermediateDirectories: true)
                }
            }
        }

        _ = try remove(Self.rosetta.id, runners: runners, libraries: libraries)

        for library in libraries {
            let left = try fm.contentsOfDirectory(
                atPath: library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                    .path(percentEncoded: false)
            ).sorted()
            #expect(left == SupportPaths.prefixTemplates(forBuild: Self.fexID, in: library)
                .map(\.lastPathComponent).sorted())
        }
    }

    @Test("Removing a build also clears templates left by builds removed while their drive was away")
    func removesTemplatesOfBuildsAlreadyGone() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fexID])
        defer { try? FileManager.default.removeItem(at: runners) }
        let fm = FileManager.default
        let library = SteamLibrary(root: runners.appending(path: "libraries/external"))
        let gone = SupportPaths.prefixTemplates(forBuild: "10.0-gone", in: library)
        for template in gone {
            try fm.createDirectory(at: template.appending(path: "pfx"), withIntermediateDirectories: true)
        }

        _ = try remove(Self.rosetta.id, runners: runners, libraries: [library])

        for template in gone { #expect(!fm.fileExists(atPath: template.path(percentEncoded: false))) }
    }

    @Test("A template is named by the build and the unix arch, under notproton-template")
    func templateNamesMatchTheScript() throws {
        let library = SteamLibrary(root: URL(filePath: "/L"))
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        let expression = try #require(script.firstMatch(of: #/runner_id="([^"]+)"/#)).1
        let cache = script.split(separator: "\n").first { $0.contains("template_cache=\"") }
        #expect(cache?.contains("$(dirname \"$STEAM_COMPAT_DATA_PATH\")/\(SupportPaths.prefixTemplateFolder)\"") == true)
        let template = script.split(separator: "\n").first { $0.contains("template_dir=\"") }
        #expect(template?.contains("template_dir=\"$template_cache/$runner_id\"") == true)
        let names = ["x86_64-unix", "aarch64-unix"].map { arch in
            expression.replacingOccurrences(of: "$np_build", with: "11.18-aaaaaaaa")
                .replacingOccurrences(of: "$wine_unix_arch", with: arch)
        }
        #expect(SupportPaths.prefixTemplates(forBuild: "11.18-aaaaaaaa", in: library).map(\.path)
            == names.map { library.compatdata.appending(path: SupportPaths.prefixTemplateFolder).appending(path: $0).path })
    }

    @Test("A build with a game still running on it is not removed")
    func keepsRunningBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(throws: StepFailure.self) { try remove(Self.rosetta.id, runners: runners, running: true) }
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
    }

    @Test("A process runs from a clone only when its executable sits inside it")
    func readsRunningExecutables() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-ps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ps = dir.appending(path: "ps")
        try """
            #!/bin/sh
            echo "/launchd"
            echo "/R/mnc-11.18-aaaaaaaa/wine/server/wineserver"
            """.write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path(percentEncoded: false))
        let path = ps.path(percentEncoded: false)

        #expect(RunnerInstaller.isRunning(from: URL(filePath: "/R/mnc-11.18-aaaaaaaa"), ps: path))
        #expect(!RunnerInstaller.isRunning(from: URL(filePath: "/R/mnc-11.18"), ps: path))
        #expect(!RunnerInstaller.isRunning(from: URL(filePath: "/R/mnc-11.19-bbbbbbbb"), ps: path))
        #expect(RunnerInstaller.isRunning(from: URL(filePath: "/R/x"), ps: "/nonexistent/ps"))
    }

    @Test("Any build can be removed, and its tools and staged copies go with it")
    func removesBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, Self.fexID])
        defer { try? FileManager.default.removeItem(at: runners) }
        let bridge = runners.appending(path: "bridge")
        let staged = NtdllPatcher.stagedCopy(of: .x86_64Windows, build: Self.fexID, in: bridge)
        try atomicReplace(staged, with: Data("fex".utf8), step: "test")

        #expect(try remove(Self.fexID, runners: runners))

        #expect(!RunnerInstaller.hasClone(forBuild: Self.fexID, runners: runners))
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        let list = try String(contentsOf: runners.appending(path: "tools"), encoding: .utf8)
        #expect(list == CompatToolList.contents(SupportedRunners.tools(for: [Self.rosetta])))

        #expect(try remove(Self.rosetta.id, runners: runners))
        #expect(try String(contentsOf: runners.appending(path: "tools"), encoding: .utf8).isEmpty)
    }

    @Test("A build with no clone reports rather than succeeding quietly")
    func refusesMissingBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(throws: StepFailure.self) {
            try remove(Self.fexID, runners: runners)
        }
    }

    @Test("A supported build whose tree never finished unpacking is listed as damaged")
    func damagedCloneIsListed() throws {
        let runners = try makeRunners(cloning: [])
        defer { try? FileManager.default.removeItem(at: runners) }

        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.rosetta.id, runners: runners),
            withIntermediateDirectories: true
        )

        #expect(RunnerStore.damagedClones(in: runners) == [Self.rosetta.id])
        #expect(RunnerStore.orphanedClones(in: runners).isEmpty)
        #expect(RunnerStore.installedBuilds(in: runners).isEmpty)
    }

    @Test("Every clone on disk lands in exactly one of the three lists")
    func cloneListsPartition() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, "1.2.3.4567"])
        defer { try? FileManager.default.removeItem(at: runners) }

        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: Self.fexID, runners: runners),
            withIntermediateDirectories: true
        )

        let installed = RunnerStore.installedBuilds(in: runners).map(\.id)
        let damaged   = RunnerStore.damagedClones(in: runners)
        let orphaned  = RunnerStore.orphanedClones(in: runners)
        let all       = installed + damaged + orphaned

        #expect(Set(all) == Set(RunnerStore.clonedBuilds(in: runners)))
        #expect(all.count == Set(all).count)
    }

    @Test("Clones of unsupported versions are listed apart from installed builds")
    func orphanedClonesAreFound() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, "1.2.3.4567"])
        defer { try? FileManager.default.removeItem(at: runners) }

        #expect(RunnerStore.orphanedClones(in: runners) == ["1.2.3.4567"])
        #expect(RunnerStore.installedBuilds(in: runners).map(\.id) == [Self.rosetta.id])
    }

    @Test("An orphaned clone can be removed")
    func removesOrphanedClone() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id, "1.2.3.4567"])
        defer { try? FileManager.default.removeItem(at: runners) }

        _ = try remove("1.2.3.4567", runners: runners)

        #expect(RunnerStore.orphanedClones(in: runners).isEmpty)
        #expect(RunnerInstaller.hasClone(forBuild: Self.rosetta.id, runners: runners))
    }

    @Test("A clone's size counts the bytes it occupies")
    func measuresCloneSize() throws {
        let runners = try makeRunners(cloning: [Self.rosetta.id])
        defer { try? FileManager.default.removeItem(at: runners) }
        let file = SupportPaths.clonedRoot(forBuild: Self.rosetta.id, runners: runners)
            .appending(path: "loader/blob")
        try Data(repeating: 0, count: 64 * 1024).write(to: file)

        #expect(RunnerStore.cloneSize(forBuild: Self.rosetta.id, runners: runners) >= 64 * 1024)
    }
}
