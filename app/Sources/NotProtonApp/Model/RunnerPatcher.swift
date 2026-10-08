// Patcher logic

import Foundation

enum RunnerPatcher {

    static let step = "Patch the compatibility tool"

    private static let dyldEntitlement = "com.apple.security.cs.allow-dyld-environment-variables"

    static let windowsBuiltins = [
        (arch: "i386-windows", name: "lsteamclient.dll"),
        (arch: "x86_64-windows", name: "lsteamclient.dll"),
    ]

    static func builtins(in root: URL) -> [(arch: String, name: String)] {
        windowsBuiltins + unixArches(in: root).map { (arch: $0, name: "lsteamclient.so") }
    }

    // MnC Wine is an x86_64 build that runs under Rosetta, so there is one unix side.
    static func unixArches(in root: URL) -> [String] {
        ["x86_64-unix"]
    }

    static func unixArch(in root: URL) -> String {
        unixArches(in: root)[0]
    }

    struct Outcome: Sendable {
        var ntdll: [WineArch] = []
        var builtins: [String] = []
        var loaders: [String] = []
        var disabled: [String] = []

        var wroteNothing: Bool { ntdll.isEmpty && builtins.isEmpty && loaders.isEmpty && disabled.isEmpty }
    }

    static func install(
        build: RunnerBuild, root: URL, bridge: URL = SupportPaths.bridge
    ) throws -> Outcome {
        var outcome = Outcome()
        outcome.ntdll = try installNtdll(build: build, root: root, bridge: bridge)
        outcome.builtins = try installBuiltins(root: root, bridge: bridge)
        outcome.loaders = try grantLoaderEntitlement(root: root)
        outcome.disabled = try disableShadowingBuiltins(root: root)
        return outcome
    }

    // The loader rewrites a d3d module name (d3d12.dll -> d3d12_d3dm.dll) and then looks the
    // builtin up by the original name, so a Wine builtin of that name wins and the D3DMetal
    // stub never loads. The release ships dxgi, d3d11 and d3d10core already moved aside; d3d12
    // is left in, which turns every D3D12 game on D3DMetal into Wine's vkd3d with no Vulkan
    // behind it. x86_64 only: the stubs are 64-bit, and 32-bit processes keep the builtins.
    static let shadowingBuiltins = ["dxgi.dll", "d3d11.dll", "d3d10core.dll", "d3d12.dll"]
    static let disabledSuffix = "builtin-disabled"

    static func disableShadowingBuiltins(root: URL) throws -> [String] {
        let fm = FileManager.default
        var moved: [String] = []
        for name in shadowingBuiltins {
            let builtin = RunnerLayout.peBuiltin(in: root, arch: WineArch.x86_64Windows.rawValue, name: name)
            guard fm.fileExists(atPath: builtin.path(percentEncoded: false)) else { continue }
            let aside = builtin.appendingPathExtension(disabledSuffix)
            try? fm.removeItem(at: aside)
            try WriteRefused.catching(builtin.path(percentEncoded: false)) { try fm.moveItem(at: builtin, to: aside) }
            moved.append(name)
        }
        return moved
    }

    static func verify(
        build: RunnerBuild, root: URL, bridge: URL = SupportPaths.bridge
    ) -> [String] {
        var wrong: [String] = []
        for arch in WineArch.allCases {
            guard let expected = build.patchedNtdll[arch] else { continue }
            let live = RunnerLayout.ntdll(in: root, arch: arch)
            guard let actual = Digest.sha256IfPresent(live) else {
                wrong.append("\(arch.rawValue)/ntdll.dll is missing")
                continue
            }
            if actual != expected {
                wrong.append("\(arch.rawValue)/ntdll.dll is not the patched copy")
            }
        }
        for builtin in builtins(in: root) {
            let installed = Digest.sha256IfPresent(
                RunnerLayout.builtin(in: root, arch: builtin.arch, name: builtin.name))
            guard let installed else {
                wrong.append("\(builtin.arch)/\(builtin.name) is missing")
                continue
            }

            let staged = Digest.sha256IfPresent(
                bridge.appending(path: "\(builtin.arch)/\(builtin.name)"))
            if let staged, staged != installed {
                wrong.append("\(builtin.arch)/\(builtin.name) is out of date")
            }
        }

        for name in shadowingBuiltins {
            let builtin = RunnerLayout.peBuiltin(in: root, arch: WineArch.x86_64Windows.rawValue, name: name)
            if FileManager.default.fileExists(atPath: builtin.path(percentEncoded: false)) {
                wrong.append("x86_64-windows/\(name) still shadows the D3DMetal stub")
            }
        }

        for loader in unixLoaders(in: root) {
            let granted = entitlements(of: loader)
            if granted?.contains(restrictedEntitlement) == true {
                if !signatureIsValid(signingTarget(for: loader)) {
                    wrong.append("\(name(of: loader)) has a broken signature")
                }
            } else if granted?.contains(dyldEntitlement) != true {
                wrong.append("\(name(of: loader)) is missing the dyld entitlement")
            }
        }

        return wrong
    }

    private static func installNtdll(
        build: RunnerBuild, root: URL, bridge: URL
    ) throws -> [WineArch] {
        var installed: [WineArch] = []

        for arch in WineArch.allCases {
            guard let expected = build.patchedNtdll[arch] else { continue }
            let staged = NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)

            guard Digest.sha256IfPresent(staged) == expected else {
                throw StepFailure(
                    step: step,
                    detail: "The patched \(arch.rawValue) ntdll has not been copied into place."
                )
            }

            let live = RunnerLayout.ntdll(in: root, arch: arch)
            if Digest.sha256IfPresent(live) == expected { continue }

            try keepClean(live)
            try atomicReplace(live, with: Data(contentsOf: staged), step: step)
            installed.append(arch)
        }

        return installed
    }

    private static func installBuiltins(root: URL, bridge: URL) throws -> [String] {
        var installed: [String] = []

        for builtin in builtins(in: root) {
            let source = bridge.appending(path: "\(builtin.arch)/\(builtin.name)")
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw StepFailure(
                    step: step,
                    detail: "\(builtin.arch)/\(builtin.name) is not in the bridge. "
                            + "Install NotProton first."
                )
            }

            let destination = RunnerLayout.builtin(in: root, arch: builtin.arch, name: builtin.name)
            if Digest.sha256IfPresent(source) == Digest.sha256IfPresent(destination) { continue }

            try atomicReplace(destination, with: Data(contentsOf: source), step: step)
            installed.append("\(builtin.arch)/\(builtin.name)")
        }

        return installed
    }

    private static func grantLoaderEntitlement(root: URL) throws -> [String] {
        var signed: [String] = []

        for loader in unixLoaders(in: root) {
            let existing = entitlements(of: loader)
            if existing?.contains(restrictedEntitlement) == true { continue }
            if existing?.contains(dyldEntitlement) == true,
               signatureIsValid(signingTarget(for: loader)) { continue }

            guard let existing, !existing.isEmpty else {
                throw StepFailure(
                    step: step,
                    detail: "\(name(of: loader)) carries no entitlements to extend."
                )
            }

            do {
                try sign(loader, addingTo: existing)
            } catch {
                restoreClean(loader)
                throw error
            }
            signed.append(name(of: loader))
        }

        return signed
    }

    static func unixLoaders(in root: URL) -> [URL] {
        let loader = RunnerLayout.loader(in: root)
        return FileManager.default.fileExists(atPath: loader.path(percentEncoded: false)) ? [loader] : []
    }

    static func name(of loader: URL) -> String {
        let parts = loader.pathComponents
        guard parts.count > 1 else { return loader.lastPathComponent }
        return parts.suffix(2).joined(separator: "/")
    }

    private static func entitlements(of loader: URL) -> String? {
        guard let result = try? Shell.run(
            "/usr/bin/codesign", ["-d", "--entitlements", ":-", loader.path(percentEncoded: false)]
        ), result.status == 0 else { return nil }
        return result.stdout
    }

    private static func sign(_ loader: URL, addingTo existing: String) throws {
        let plist = FileManager.default.temporaryDirectory
            .appending(path: "np-entitlements-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: plist) }

        try Data(existing.utf8).write(to: plist)
        _ = try Shell.run("/usr/libexec/PlistBuddy", [
            "-c", "Add :\(dyldEntitlement) bool true", plist.path(percentEncoded: false),
        ])

        try keepClean(loader)
        let target = signingTarget(for: loader)
        let result = try Shell.run("/usr/bin/codesign", [
            "-f", "-s", "-", "--options", "runtime",
            "--entitlements", plist.path(percentEncoded: false),
            target.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }


        guard entitlements(of: loader)?.contains(dyldEntitlement) == true else {
            throw StepFailure(
                step: step,
                detail: "\(name(of: loader)) was re-signed without the dyld entitlement."
            )
        }
    }

    private static func signingTarget(for loader: URL) -> URL {
        enclosingBundle(of: loader) ?? loader
    }

    private static func enclosingBundle(of loader: URL) -> URL? {
        var candidate = loader.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    static let restrictedEntitlement = "com.apple.developer.cross-architecture-support"

    private static func signatureIsValid(_ target: URL) -> Bool {
        guard let result = try? Shell.run(
            "/usr/bin/codesign", ["--verify", "--strict", target.path(percentEncoded: false)]
        ) else { return false }
        return result.status == 0
    }

    private static func keepClean(_ file: URL) throws {
        let backup = Clean.copy(of: file)
        guard backup == file else { return }

        let destination = file.appendingPathExtension(Clean.backupSuffix)
        let result = try Shell.run("/bin/cp", [
            "-p", file.path(percentEncoded: false), destination.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: "Keeping the shipped \(file.lastPathComponent) failed. "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func restoreClean(_ file: URL) {
        let backup = file.appendingPathExtension(Clean.backupSuffix)
        guard FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) else { return }
        _ = try? Shell.run("/bin/cp", [
            "-p", backup.path(percentEncoded: false), file.path(percentEncoded: false),
        ])
    }

}
