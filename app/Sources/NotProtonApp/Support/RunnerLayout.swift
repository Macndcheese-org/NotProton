// Where things live inside an MnC Wine build tree. The release ships the build
// directory as-is rather than an installed tree, so every builtin sits under its
// own module folder: dlls/ntdll/x86_64-windows/ntdll.dll, dlls/ntdll/ntdll.so.

import Foundation

enum RunnerLayout {

    static let loaderPath = "loader/wine"
    static let wineserverPath = "server/wineserver"
    static let d3dPackPath = "mnc-d3d"
    static let rosettaPath = "mnc-rosetta"

    static func loader(in root: URL) -> URL {
        root.appending(path: loaderPath)
    }

    static func wineserver(in root: URL) -> URL {
        root.appending(path: wineserverPath)
    }

    static func d3dPack(in root: URL) -> URL {
        root.appending(path: d3dPackPath)
    }

    static func ntdll(in root: URL, arch: WineArch) -> URL {
        peBuiltin(in: root, arch: arch.rawValue, name: "ntdll.dll")
    }

    static func moduleDir(in root: URL, name: String) -> URL {
        root.appending(path: "dlls/\(stem(of: name))")
    }

    // A PE builtin, by Windows arch folder (x86_64-windows, i386-windows).
    static func peBuiltin(in root: URL, arch: String, name: String) -> URL {
        moduleDir(in: root, name: name).appending(path: "\(arch)/\(name)")
    }

    // A unix library, which a build tree keeps beside its module's arch folders.
    static func unixLib(in root: URL, name: String) -> URL {
        moduleDir(in: root, name: name).appending(path: name)
    }

    // Either kind, by the arch folder a bridge file is staged under.
    static func builtin(in root: URL, arch: String, name: String) -> URL {
        arch.hasSuffix("-unix") ? unixLib(in: root, name: name) : peBuiltin(in: root, arch: arch, name: name)
    }

    static func stem(of name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[..<dot])
    }
}
