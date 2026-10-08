// One row per MnC Wine build on the Status pane

import Foundation

struct WineRow: Identifiable, Equatable {

    enum Copy: Equatable {
        case none
        case ready
        case unpatched
        case damaged
        case unsupported
    }

    let buildID: String
    let archive: WineArchive?
    let copy: Copy
    let unsupportedHash: String?

    var id: String { archive?.id ?? buildID }
    var build: RunnerBuild? { SupportedRunners.build(id: buildID) }

    var title: String {
        if let archive, copy == .none || unsupportedHash != nil { return archive.name }
        return SupportedRunners.displayVersion(forID: buildID)
    }

    var canSetUp: Bool { archive != nil && unsupportedHash == nil }
    var isManual: Bool { archive?.isManual ?? false }

    static func == (a: WineRow, b: WineRow) -> Bool {
        a.buildID == b.buildID && a.archive?.id == b.archive?.id && a.copy == b.copy
            && a.unsupportedHash == b.unsupportedHash
    }

    static func rows(
        archives: [WineArchive],
        installed: [RunnerBuild],
        damaged: [String],
        orphaned: [String],
        unpatched: [String]
    ) -> [WineRow] {
        var rows: [WineRow] = []
        var seen: Set<String> = []

        func copy(of build: String) -> Copy {
            if unpatched.contains(build) { return .unpatched }
            if installed.contains(where: { $0.id == build }) { return .ready }
            if damaged.contains(build) { return .damaged }
            return .none
        }

        for archive in archives {
            switch archive.support {
            case .supported(let build):
                guard seen.insert(build.id).inserted else { continue }
                rows.append(WineRow(
                    buildID: build.id, archive: archive, copy: copy(of: build.id), unsupportedHash: nil
                ))
            case .unsupportedBuild(let hash):
                rows.append(WineRow(buildID: "", archive: archive, copy: .none, unsupportedHash: hash))
            case .unreadable:
                continue
            }
        }

        let copies = installed.map(\.id) + damaged
        for build in copies where seen.insert(build).inserted {
            rows.append(WineRow(buildID: build, archive: nil, copy: copy(of: build), unsupportedHash: nil))
        }
        for build in orphaned where seen.insert(build).inserted {
            rows.append(WineRow(buildID: build, archive: nil, copy: .unsupported, unsupportedHash: nil))
        }
        return rows
    }

    // The row a picked tarball already shows up under. Supported tarballs match by build.
    static func listing(_ archive: WineArchive, in rows: [WineRow]) -> WineRow? {
        if case .supported(let build) = archive.support {
            return rows.first { $0.buildID == build.id && $0.archive != nil }
        }
        return rows.first { $0.archive.map { MncWineSource.same($0.file, archive.file) } ?? false }
    }
}
