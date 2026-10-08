// MnC Wine is an x86_64 build and loads FreeType and GnuTLS at runtime from
// whatever x86_64 copies the Mac has: Intel Homebrew under /usr/local, or the
// closure MacNdCheese keeps in its deps folder. The run script searches the same
// folders through DYLD_FALLBACK_LIBRARY_PATH.

import Foundation

enum RuntimeLibraries {

    struct Library: Sendable, Equatable {
        let file: String
        let purpose: String
    }

    static let required = [
        Library(file: "libfreetype.6.dylib", purpose: "FreeType (fonts)"),
        Library(file: "libgnutls.30.dylib", purpose: "GnuTLS (secure connections)"),
    ]

    static var searchDirs: [URL] {
        let deps = SupportPaths.macNCheeseDeps
        return [
            "/usr/local/opt/freetype/lib", "/usr/local/opt/fontconfig/lib", "/usr/local/opt/gnutls/lib",
            "/usr/local/lib",
        ].map { URL(filePath: $0, directoryHint: .isDirectory) }
            + ["mnc-fonts", "mnc-tls"].map { deps.appending(path: $0, directoryHint: .isDirectory) }
    }

    static func missing(in dirs: [URL] = searchDirs) -> [Library] {
        let fm = FileManager.default
        return required.filter { library in
            !dirs.contains { fm.fileExists(atPath: $0.appending(path: library.file).path(percentEncoded: false)) }
        }
    }
}
