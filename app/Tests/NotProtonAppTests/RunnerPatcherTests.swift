import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner patching")
struct RunnerPatcherTests {

    // Only real MnC Wine bytes can answer whether a repair works, since no tree a test builds
    // meets the pinned hashes. An APFS clone costs a second and leaves the real one alone, so
    // it is made beside the real tree, on whatever drive runners/ points at.
    private static func healthyClone() throws -> (root: URL, build: RunnerBuild)? {
        guard let build = RunnerStore.installedBuilds().first(where: {
            RunnerPatcher.verify(build: $0, root: SupportPaths.clonedRoot(forBuild: $0.id)).isEmpty
        }) else { return nil }
        let live = SupportPaths.clonedRoot(forBuild: build.id).resolvingSymlinksInPath()

        let scratch = live.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".notproton-test-runner-\(UUID().uuidString)")
        let copied = try Shell.run("/bin/cp", [
            "-c", "-R", live.path(percentEncoded: false), scratch.path(percentEncoded: false),
        ])

        // Past the healthy check, a clone that cannot be read is this test breaking and
        // not a machine that cannot answer, so it fails rather than skipping.
        try #require(copied.status == 0)
        try #require(RunnerPatcher.verify(build: build, root: scratch).isEmpty)

        return (scratch, build)
    }

    // The launch path used to copy this on every run, so the button is now the only thing
    // that closes the gap after an app update replaces the bridge copy.
    @Test("A builtin the bridge has replaced is reported, then repaired by the install")
    func repairsStaleBuiltin() throws {
        guard let (root, build) = try Self.healthyClone() else { return }
        defer { try? FileManager.default.removeItem(at: root) }

        let arch = RunnerPatcher.unixArch(in: root)
        let builtin = RunnerLayout.builtin(in: root, arch: arch, name: "lsteamclient.so")
        try Data("not the bridge copy".utf8).write(to: builtin)

        #expect(RunnerPatcher.verify(build: build, root: root)
            == ["\(arch)/lsteamclient.so is out of date"])

        let outcome = try RunnerPatcher.install(build: build, root: root)
        #expect(outcome.builtins == ["\(arch)/lsteamclient.so"])
        #expect(RunnerPatcher.verify(build: build, root: root).isEmpty)
    }

    @Test("A builtin that was never installed is reported, then repaired by the install")
    func repairsMissingBuiltin() throws {
        guard let (root, build) = try Self.healthyClone() else { return }
        defer { try? FileManager.default.removeItem(at: root) }

        let builtin = RunnerLayout.peBuiltin(in: root, arch: "i386-windows", name: "lsteamclient.dll")
        try FileManager.default.removeItem(at: builtin)

        #expect(RunnerPatcher.verify(build: build, root: root)
            == ["i386-windows/lsteamclient.dll is missing"])

        _ = try RunnerPatcher.install(build: build, root: root)
        #expect(RunnerPatcher.verify(build: build, root: root).isEmpty)
    }

    // A runner back on stock ntdll runs games that fail their ownership check, which is
    // the failure this whole path exists to prevent.
    @Test("A runner back on stock ntdll is reported, then repaired by the install")
    func repairsStockNtdll() throws {
        guard let (root, build) = try Self.healthyClone() else { return }
        defer { try? FileManager.default.removeItem(at: root) }

        let arch = WineArch.x86_64Windows
        let live = RunnerLayout.ntdll(in: root, arch: arch)
        let clean = NtdllPatcher.cleanSource(inRoot: root, arch: arch)
        guard clean != live else { return }

        try Data(contentsOf: clean).write(to: live)
        #expect(RunnerPatcher.verify(build: build, root: root)
            == ["\(arch.rawValue)/ntdll.dll is not the patched copy"])

        let outcome = try RunnerPatcher.install(build: build, root: root)
        #expect(outcome.ntdll == [arch])
        #expect(Digest.sha256IfPresent(live) == build.patchedNtdll[arch])
        #expect(RunnerPatcher.verify(build: build, root: root).isEmpty)
    }

    // Without the entitlement dyld drops the overlay insert and the game still runs, so
    // nothing but this check reports it.
    @Test("A loader signed without the dyld entitlement is reported, then repaired")
    func repairsStrippedEntitlement() throws {
        guard let (root, build) = try Self.healthyClone() else { return }
        defer { try? FileManager.default.removeItem(at: root) }

        let loader = RunnerLayout.loader(in: root)
        let clean = Clean.copy(of: loader)
        guard clean != loader else { return }

        try #require(try Shell.run("/bin/cp", [
            "-p", clean.path(percentEncoded: false), loader.path(percentEncoded: false),
        ]).status == 0)

        #expect(RunnerPatcher.verify(build: build, root: root)
            == ["loader/wine is missing the dyld entitlement"])

        let outcome = try RunnerPatcher.install(build: build, root: root)
        #expect(outcome.loaders == ["loader/wine"])
        #expect(RunnerPatcher.verify(build: build, root: root).isEmpty)
    }

    // An update of the tree that brings Wine's own d3d12 back would quietly put D3D12 games on
    // vkd3d again, so verification reports it and the install moves it aside.
    @Test("A Wine d3d12 builtin that came back is reported, then moved aside by the install")
    func repairsShadowingD3D12() throws {
        guard let (root, build) = try Self.healthyClone() else { return }
        defer { try? FileManager.default.removeItem(at: root) }

        let builtin = RunnerLayout.peBuiltin(in: root, arch: "x86_64-windows", name: "d3d12.dll")
        try FileManager.default.moveItem(
            at: builtin.appendingPathExtension(RunnerPatcher.disabledSuffix), to: builtin)

        #expect(RunnerPatcher.verify(build: build, root: root)
            == ["x86_64-windows/d3d12.dll still shadows the D3DMetal stub"])

        let outcome = try RunnerPatcher.install(build: build, root: root)
        #expect(outcome.disabled == ["d3d12.dll"])
        #expect(RunnerPatcher.verify(build: build, root: root).isEmpty)
    }

    // Re-running has to be free, or the button cannot be the answer to every runner
    // problem the UI reports.
    @Test("Installing into a runner that is already right writes nothing")
    func installIsIdempotent() throws {
        guard let (root, build) = try Self.healthyClone() else { return }
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try RunnerPatcher.install(build: build, root: root)
        #expect(outcome.wroteNothing)
    }

    // A loader that is not found never gets the dyld entitlement. Silent at install, it shows
    // up as a game with no dylib.
    @Test("Loader discovery finds the build tree's loader and nothing else")
    func loaderDiscoveryFindsTheTreeLoader() throws {
        let fm = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "notproton-loaders-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        #expect(RunnerPatcher.unixLoaders(in: root).isEmpty)

        // A windows builtin named like the loader must not be mistaken for it.
        let windows = root.appending(path: "dlls/wine/x86_64-windows/wine")
        try fm.createDirectory(at: windows.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: windows)
        try markClone(root)

        // Compared by name rather than by URL, since the temporary directory is reached
        // through a symlink that only one of the two sides resolves.
        #expect(RunnerPatcher.unixLoaders(in: root).map(RunnerPatcher.name(of:)) == ["loader/wine"])
    }

    // The run script stages the bridge's unix builtin under x86_64-unix, so the app installs
    // the same one into the build tree.
    @Test("The unix builtin is the x86_64 one, installed beside its module")
    func unixBuiltinIsX86() throws {
        let root = URL(filePath: "/R/mnc-11.18-aaaaaaaa/wine")
        #expect(RunnerPatcher.unixArch(in: root) == "x86_64-unix")

        let builtins = RunnerPatcher.builtins(in: root)
        #expect(builtins.map(\.arch) == RunnerPatcher.windowsBuiltins.map(\.arch) + ["x86_64-unix"])
        #expect(builtins.allSatisfy { $0.name.hasPrefix("lsteamclient") })
        #expect(RunnerLayout.builtin(in: root, arch: "x86_64-unix", name: "lsteamclient.so")
            == root.appending(path: "dlls/lsteamclient/lsteamclient.so"))
        #expect(RunnerLayout.builtin(in: root, arch: "i386-windows", name: "lsteamclient.dll")
            == root.appending(path: "dlls/lsteamclient/i386-windows/lsteamclient.dll"))
    }

    @Test("Wine's x86_64 d3d builtins are moved aside so the D3DMetal stubs load, and only those")
    func disablesShadowingBuiltins() throws {
        let fm = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "notproton-shadow-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ arch: String, _ name: String) throws {
            let file = RunnerLayout.peBuiltin(in: root, arch: arch, name: name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: file)
        }
        try write("x86_64-windows", "d3d12.dll")
        try write("i386-windows", "d3d12.dll")
        try write("x86_64-windows", "d3d10.dll")

        #expect(try RunnerPatcher.disableShadowingBuiltins(root: root) == ["d3d12.dll"])
        #expect(try RunnerPatcher.disableShadowingBuiltins(root: root).isEmpty)

        let x64 = RunnerLayout.peBuiltin(in: root, arch: "x86_64-windows", name: "d3d12.dll")
        #expect(!fm.fileExists(atPath: x64.path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: x64.appendingPathExtension("builtin-disabled").path(percentEncoded: false)))
        // The 32-bit builtin and Wine's d3d10 API layer stay where they are.
        #expect(fm.fileExists(atPath: RunnerLayout.peBuiltin(in: root, arch: "i386-windows", name: "d3d12.dll")
            .path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: RunnerLayout.peBuiltin(in: root, arch: "x86_64-windows", name: "d3d10.dll")
            .path(percentEncoded: false)))
    }
}
