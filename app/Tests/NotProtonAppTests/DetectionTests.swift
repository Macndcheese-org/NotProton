import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner allow list")
struct SupportedRunnerTests {

    // The arches a build carries need both hashes: an input with no output leaves the patch
    // unverified, and an output with no input patches a file nothing had checked.
    @Test("Every row's pin hashes are complete for the arches it claims")
    func rowsAreComplete() {
        #expect(!SupportedRunners.all.isEmpty)

        for build in SupportedRunners.all {
            expectSHA256(build.loaderSHA256, "loader for \(build.id)")
            #expect(!build.cleanNtdll.isEmpty, "\(build.id) patches nothing")
            #expect(Set(build.cleanNtdll.keys) == Set(build.patchedNtdll.keys), "\(build.id) is lopsided")

            for (arch, clean) in build.cleanNtdll {
                let patched = build.patchedNtdll[arch]
                expectSHA256(clean, "clean \(arch.rawValue)")
                expectSHA256(patched ?? "", "patched \(arch.rawValue)")

                // A patch that produced its own input would mean the patcher did
                // nothing, and the launch path would silently run stock ntdll.
                #expect(clean != patched)
            }
        }
    }

    @Test("Identities are unique so lookup is unambiguous")
    func identitiesAreUnique() {
        let ids = SupportedRunners.all.map(\.id)
        #expect(Set(ids).count == ids.count)

        let loaders = SupportedRunners.all.map(\.loaderSHA256)
        #expect(Set(loaders).count == loaders.count)
    }

    @Test("A build id is the Wine version and its loader hash, and names the runner folder")
    func buildIDShape() {
        for build in SupportedRunners.all {
            #expect(build.flavor == nil)
            #expect(build.id == build.bundleVersion)
            #expect(build.id == "\(build.releaseVersion)-\(build.loaderSHA256.prefix(8))")
            #expect(build.displayVersion == "MnC Wine \(build.releaseVersion)")
        }
    }

    // The installed row has only the runner folder name, which is the id.
    @Test("An installed build is named the same way the picked one is")
    func installedBuildsReadBackTheSame() {
        for build in SupportedRunners.all {
            #expect(SupportedRunners.displayVersion(forID: build.id) == build.displayVersion)
        }

        // A tree off the allow list still has to say something, and its directory name is
        // all there is to say.
        #expect(SupportedRunners.displayVersion(forID: "11.0-00000000") == "11.0-00000000")
    }

    @Test("Every build is recognized by its release tarball")
    func archiveLookup() {
        for build in SupportedRunners.all {
            let hash = try! #require(build.archiveSHA256)
            #expect(SupportedRunners.build(archiveSHA256: hash) == build)
        }
        #expect(SupportedRunners.build(archiveSHA256: "") == nil)
    }

    @Test("Lookup matches on an exact loader hash only")
    func lookupIsExact() {
        let build = SupportedRunners.all[0]
        #expect(SupportedRunners.build(loaderSHA256: build.loaderSHA256) != nil)
        #expect(SupportedRunners.build(loaderSHA256: String(build.loaderSHA256.dropLast())) == nil)
        #expect(SupportedRunners.build(loaderSHA256: build.loaderSHA256 + " ") == nil)
        #expect(SupportedRunners.build(id: build.id) != nil)
        #expect(SupportedRunners.build(id: build.id + " ") == nil)
    }

    private func expectSHA256(_ value: String, _ label: String) {
        #expect(value.count == 64, "\(label) is not a sha256")
        #expect(value.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(label) is not lowercase hex")
    }
}

@Suite("Steam tools")
struct CompatToolOrderTests {

    @Test("The MnC Wine build serves one Rosetta tool")
    func mncTool() throws {
        let tools = SupportedRunners.tools(for: SupportedRunners.all)
        #expect(tools.map(\.name) == ["notproton-mnc"])
        #expect(tools.first?.tool.flavor == .rosetta)
        #expect(SupportedRunners.toolPreference.first == tools.first?.name)
    }

    @Test("Every tool name is one the dylib accepts")
    func namesParse() {
        for tool in SupportedRunners.all.flatMap(\.tools) {
            #expect(tool.name.hasPrefix("notproton"))
            #expect(tool.name.contains("proton"))
            #expect(tool.name.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) })
            #expect(!tool.display.contains { "\"\\".contains($0) || $0.isNewline })
        }
    }

    @Test("The list file has one tab-separated line per tool")
    func contents() throws {
        let build = SupportedRunners.all[0]
        let tools = SupportedRunners.tools(for: [build])
        #expect(CompatToolList.contents(tools)
            == "notproton-mnc\t\(build.id)\trosetta\tMnC Wine 11.18\n")
    }
}

@Suite("Signature database selection")
struct SignatureSelectionTests {

    @Test("The highest numbered database wins, not the first listed")
    func picksHighestBuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "np-signature-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["1788400362.json", "999999999.json", "1788400363.json", "notes.txt"] {
            try Data().write(to: directory.appending(path: name))
        }

        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == "1788400363.json")
    }

    @Test("An empty or absent directory reports nothing staged")
    func handlesEmptyDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "np-signature-empty-\(UUID().uuidString)")
        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == nil)
    }
}

@Suite("Support paths")
struct SupportPathTests {

    // These strings are a contract with the dylib and RUN_SCRIPT rather than a
    // preference, so they are pinned here to make a rename visible.
    @Test("Paths match what the dylib and the run script use")
    func pathsAreStable() {
        let support = SupportPaths.support.path(percentEncoded: false)
        #expect(support.hasSuffix("/Library/Application Support/notproton"))

        #expect(SupportPaths.signatures.path(percentEncoded: false)
            .hasSuffix("/notproton/signatures/macos.arm64"))
        #expect(SupportPaths.overlayShim.path(percentEncoded: false)
            .hasSuffix("/notproton/overlay-shim.dylib"))
        #expect(SupportPaths.toolList.path(percentEncoded: false)
            .hasSuffix("/notproton/tools"))
        #expect(SupportPaths.Steam.deployedDylib.path(percentEncoded: false)
            == "/Applications/Steam.app/Contents/MacOS/notproton.dylib")
        #expect(SupportPaths.Steam.infoPlist.path(percentEncoded: false)
            == "/Applications/Steam.app/Contents/Info.plist")
    }
}
