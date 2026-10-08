// Allow list of MnC Wine builds the runner installs from. The ntdll hook sites
// are hardcoded RVAs, so a build not pinned here would be patched at the wrong
// offsets. New builds go in after running ntdll-patch/resolve.py and pinning
// the hashes.

import Foundation

enum WineArch: String, Sendable, CaseIterable {
    case x86_64Windows = "x86_64-windows"
    case i386Windows = "i386-windows"
    case aarch64Windows = "aarch64-windows"
}

struct RunnerBuild: Sendable, Equatable, Identifiable {
    // Names the directory under runners/ and keys the ntdll hash tables. Changing it
    // orphans an installed runner.
    let bundleVersion: String

    // The Wine version the build reports. Display only, never identity.
    let releaseVersion: String

    let flavor: String?

    // loader/wine in the build tree.
    let loaderSHA256: String

    let cleanNtdll: [WineArch: String]
    let patchedNtdll: [WineArch: String]

    var tools: [CompatTool] = []

    // The release tarball this build is installed from, so a tarball can be recognized
    // without unpacking it.
    var archiveSHA256: String?

    var id: String { flavor.map { "\(bundleVersion)-\($0)" } ?? bundleVersion }

    var flavorName: String { flavor?.uppercased() ?? "Rosetta" }

    var displayVersion: String { "MnC Wine \(releaseVersion)" }
}

struct CompatTool: Sendable, Hashable, Identifiable {
    enum Flavor: String, Sendable, CaseIterable {
        case rosetta
        case fex

        var name: String { self == .fex ? "FEX" : "Rosetta" }
        var unixDir: String { self == .fex ? "aarch64-unix" : "x86_64-unix" }
    }

    let name: String
    let flavor: Flavor
    let display: String

    var id: String { name }

    var prefixArch: PrefixArch { flavor == .fex ? .arm64 : .x86_64 }
}

struct InstalledTool: Sendable, Hashable, Identifiable {
    let tool: CompatTool
    let build: String

    var id: String { tool.name }
    var name: String { tool.name }
    var display: String { tool.display }
}

enum SupportedRunners {

    // First entry is what windows-only games get when Steam has no mapping.
    static let toolPreference = ["notproton-mnc"]

    static let legacyToolName = "notproton"

    // The only builds that can own the 'notproton' tool name. MnC Wine builds never
    // shipped under it.
    static let legacyHolders: [String] = []

    enum LegacyHolder: Equatable, Sendable {
        case build(String)
        case nobody
    }

    static func tools(for builds: [RunnerBuild], legacy: LegacyHolder = .nobody) -> [InstalledTool] {
        let installed = Set(builds.map(\.id))
        let holder: String? = switch legacy {
        case .build(let id): id
        case .nobody: nil
        }
        let served = all.filter { installed.contains($0.id) }.flatMap { build in
            build.tools.enumerated().map { index, tool in
                let name = build.id == holder && index == 0 ? legacyToolName : tool.name
                return InstalledTool(
                    tool: CompatTool(name: name, flavor: tool.flavor, display: tool.display), build: build.id
                )
            }
        }
        func rank(_ tool: InstalledTool) -> Int {
            toolPreference.firstIndex(of: tool.name) ?? toolPreference.count
        }
        return served.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static let all: [RunnerBuild] = [
        RunnerBuild(
            bundleVersion: "11.18-c8fd07a0",
            releaseVersion: "11.18",
            flavor: nil,
            loaderSHA256: "c8fd07a04ab02d969e0ec8f51191771ba863cb16ba4a14860be6bf848c0534a8",
            cleanNtdll: [
                .x86_64Windows: "3b3b3cc1359682555013d58c95d483f8d11a6485040ddfe3b9ea0bfdb1a6e1c7",
                .i386Windows: "85755ffc284d2c7e2ab4695794004d1a7437bbd8b12d9455813004bb87b2943e",
            ],
            patchedNtdll: [
                .x86_64Windows: "78899bb12971e9feaca652e3c2ad6d7329d569e135c2919c5c18c25f69b2733e",
                .i386Windows: "6cbf6fa273a04b673c37b05350be5d7cf67ca960c7744bb367a043436d9c4be5",
            ],
            tools: [
                CompatTool(name: "notproton-mnc", flavor: .rosetta, display: "MnC Wine 11.18"),
            ],
            archiveSHA256: "1531fdaed80847b593e9fcd07dc073a789203107d2f2366e535d7a848139ed37"
        ),
    ]

    static func build(loaderSHA256 hash: String) -> RunnerBuild? {
        all.first { $0.loaderSHA256 == hash }
    }

    static func build(archiveSHA256 hash: String) -> RunnerBuild? {
        all.first { $0.archiveSHA256 == hash }
    }

    static func build(id: String) -> RunnerBuild? {
        all.first { $0.id == id }
    }

    static func displayVersion(forID id: String) -> String {
        build(id: id)?.displayVersion ?? id
    }

    static var versionList: String {
        var seen = Set<String>()
        return all.map(\.displayVersion)
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}
