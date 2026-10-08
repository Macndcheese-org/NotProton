import Foundation
import Testing

@testable import NotProtonApp

@Suite("Launch environment")
struct LaunchEnvTests {

    private static func runScript() throws -> String {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
    }

    private static func line(containing needles: String...) throws -> String {
        let script = try runScript()
        return try #require(
            script.split(separator: "\n")
                .first { line in needles.allSatisfy(line.contains) }
                .map(String.init),
            "compat_run.sh no longer has a line containing \(needles.joined(separator: " and "))")
    }

    @Test("A launch option cannot unhook the steamclient overrides")
    func overridesKeepTheTrioLast() throws {
        let line = try Self.line(
            containing: "export WINEDLLOVERRIDES=", "steamclient=n;steamclient64=n;lsteamclient=b")
        let user = try #require(line.range(of: "${WINEDLLOVERRIDES:+"))
        let trio = try #require(line.range(of: "steamclient=n;steamclient64=n;lsteamclient=b"))
        #expect(
            user.lowerBound < trio.lowerBound,
            "the trio must follow the launch option, because ntdll keeps the last setting")
    }

    // A build tree resolves its own builtins before anything on WINEDLLPATH, so the path only
    // carries the bridge, which has to come ahead of a launch option.
    @Test("A launch option cannot shadow the bridge dlls")
    func dllPathKeepsTheBridgeFirst() throws {
        let line = try Self.line(containing: "export WINEDLLPATH=", "$prefix_steam")
        let bridge = try #require(line.range(of: "$prefix_steam"))
        let user = try #require(line.range(of: "$WINEDLLPATH"))
        #expect(
            bridge.lowerBound < user.lowerBound,
            "the bridge must precede the launch option, because the loader takes the first match")
    }

    @Test("The prefix and loader are not taken from launch options")
    func ownedVarsAreOverwritten() throws {
        _ = try Self.line(containing: "export WINEPREFIX=", "STEAM_COMPAT_DATA_PATH")

        let script = try Self.runScript()
        for name in ["WINEPREFIX", "WINELOADER", "WINESERVER"] {
            #expect(
                !script.contains("${\(name):-"),
                "\(name) must not fall back to what it inherits, which a launch option now sets")
        }

        // The loader and server come from the build tree, whatever a launch option sets.
        _ = try Self.line(containing: "WINELOADER=\"$MNC_ROOT/loader/wine\"")
        _ = try Self.line(containing: "WINESERVER=\"$MNC_ROOT/server/wineserver\"")
    }
}
