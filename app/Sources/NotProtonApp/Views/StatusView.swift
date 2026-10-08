// 'Status' view, see SystemStatus for actual logic

import SwiftUI

enum StatusTone: Sendable {
    case ok, info, warning, bad, neutral

    var symbol: String {
        switch self {
        case .ok: "circle.fill"
        case .info: "circle"
        case .warning: "circle.fill"
        case .bad: "circle.fill"
        case .neutral: "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}

struct StatusAction {
    let label: String
    var isProminent = false
    var role: ButtonRole?
    var help: String?
    var isEnabled = true
    var startsGroup = false
    let perform: () -> Void
}

enum StatusMetrics {
    static let symbolWidth: CGFloat = 10
    static let symbolSpacing: CGFloat = 8
    static var textInset: CGFloat { symbolWidth + symbolSpacing }
}

struct StatusRow: View {

    let title: String
    var value: String?

    var tone: StatusTone?
    var detail: String?
    var trailing: String?
    var secondaryAction: StatusAction?
    var action: StatusAction?
    var menu: [StatusAction] = []
    var toggle: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: StatusMetrics.symbolSpacing) {
                if let tone {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(tone.color)
                        .frame(width: StatusMetrics.symbolWidth)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: StatusMetrics.symbolWidth, height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let value {
                        Text(value)
                            .foregroundStyle(.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if secondaryAction != nil || action != nil || !menu.isEmpty || toggle != nil || trailing != nil {
                Spacer(minLength: 12)
            }
            if let trailing {
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, action == nil && menu.isEmpty ? 0 : 8)
            }
            if let toggle {
                Toggle(title, isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let secondaryAction {
                button(secondaryAction)
                    .disabled(!secondaryAction.isEnabled)
                    .help(secondaryAction.help ?? "")
                    .accessibilityLabel("\(secondaryAction.label), \(title)")
                    .padding(.trailing, 8)
            }
            if let action {
                button(action)
                    .disabled(!action.isEnabled)
                    .help(action.help ?? "")
                    .accessibilityLabel("\(action.label), \(title)")
            }
            if !menu.isEmpty {
                Menu {
                    menuItems(menu, hidingUnavailable: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions, \(title)")
                .padding(.leading, action == nil ? 0 : 8)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            menuItems([action, secondaryAction].compactMap { $0 } + menu, hidingUnavailable: true)
        }
    }

    @ViewBuilder
    private func menuItems(_ items: [StatusAction], hidingUnavailable: Bool) -> some View {
        let shown = hidingUnavailable ? items.filter(\.isEnabled) : items
        ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
            if item.startsGroup && index > 0 { Divider() }
            Button(item.label, role: item.role, action: item.perform)
                .disabled(!item.isEnabled)
        }
    }

    @ViewBuilder
    private func button(_ action: StatusAction) -> some View {
        if action.isProminent {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.bordered)
        }
    }
}

struct StatusView: View {
    @Environment(SystemStatus.self) private var status

    private static let updateBlockPrompt =
        "Steam client updates may break NotProton. If you don't want to wait for "
            + "NotProton to be updated to be compatible with future Steam versions at the "
            + "cost of not getting updates to the Steam client, you can stop the Steam "
            + "client from updating itself."

    var body: some View {
        Group {
            if let snapshot = status.snapshot {
                statusForm(snapshot)
            } else {
                ProgressView("Checking")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Status")
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItem(placement: .primaryAction) { refreshButton }
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .primaryAction) { refreshButton }
            }
        }
        .confirmationDialog(
            "Block Steam client updates?",
            isPresented: asking(.blockUpdates),
            titleVisibility: .visible
        ) {
            Button("Block Updates", role: .destructive) {
                Task { await status.setUpdateBlock(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.updateBlockPrompt)
        }
        .confirmationDialog(
            "Replace Steam with Valve's bundle?",
            isPresented: asking(.replaceSteam),
            titleVisibility: .visible
        ) {
            Button("Replace Steam", role: .destructive) {
                Task { await status.repairSteam() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will restore Steam itself to its original state but does not remove "
                    + "the support components used by NotProton."
            )
        }
        .confirmationDialog(
            status.pendingRemoval.map {
                "Remove the \(SupportedRunners.displayVersion(forID: $0)) copy?"
            } ?? "",
            isPresented: asking(.removeBuild),
            titleVisibility: .visible
        ) {
            Button("Remove Copy", role: .destructive) {
                Task { await status.removePendingBuild() }
            }
            Button("Cancel", role: .cancel) { status.cancelBuildRemoval() }
        } message: {
            Text("The release tarball itself is not removed.")
        }
        .confirmationDialog(
            "Remove everything NotProton has created?",
            isPresented: asking(.removeEverything),
            titleVisibility: .visible
        ) {
            Button("Remove Everything", role: .destructive) {
                Task { await status.removeEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Steam is restored to its unmodified state and NotProton is removed, including "
                    + "the compatibility tool that lives inside the Steam folder. Windows games "
                    + "and Steam Play prefixes are not removed."
            )
        }
        .task { if status.snapshot == nil { await status.refresh() } }
    }

    private func asking(_ confirmation: SystemStatus.Confirmation) -> Binding<Bool> {
        Binding(
            get: { status.pendingConfirmation == confirmation },
            set: { shown in
                if !shown, status.pendingConfirmation == confirmation {
                    status.pendingConfirmation = nil
                }
            }
        )
    }

    private func statusForm(_ snapshot: StatusSnapshot) -> some View {
        ScrollViewReader { proxy in
            form(snapshot)
                .onChange(of: status.highlightedRow) { _, row in
                    guard let row else { return }
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
                }
        }
    }

    private func form(_ snapshot: StatusSnapshot) -> some View {
        Form {
            if let failure = status.failure {
                StatusRow(
                    title: "Failed",
                    value: failure,
                    tone: .bad,
                    action: status.failureRemedy?.settingsPane.map { pane in
                        StatusAction(label: Remedy.settingsButton) {
                            Remedy.openSettings(pane)
                        }
                    }
                )
            } else if let outcome = status.outcome {
                StatusRow(title: "Done", value: outcome, tone: .ok)
            }

            if let failure = status.templateCleanupFailure {
                StatusRow(title: "Template cleanup incomplete", value: failure, tone: .warning)
            }

            if let activity = status.activity {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Steam") {
                steamRow(snapshot.steam, payload: snapshot.payload)
                sharedInsertRow(snapshot.otherInserts, steam: snapshot.steam)
                if snapshot.steamRunning {
                    StatusRow(
                        title: "Steam is running",
                        value: "Close Steam before continuing.",
                        tone: .info
                    )
                }
                updateBlockRow(snapshot.updateBlocked)
                StatusRow(
                    title: "Controller permission",
                    value: "Clear Steam's controller permission so macOS asks for it again.",
                    action: StatusAction(
                        label: "Reset",
                        isEnabled: status.isIdle
                    ) { Task { await status.resetControllerPermission() } }
                )
            }

            Section {
                wineSection(snapshot)
            } header: {
                Text("MnC Wine")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Release\u{2026}") { Task { await status.addArchive() } }
                        .disabled(!status.isIdle)
                        .help("Add an MnC Wine release tarball from another folder.")
                }
            }

            componentsSection(snapshot.payload)

            dangerSection
        }
        .formStyle(.grouped)
    }

    private var dangerSection: some View {
        Section {
            StatusRow(
                title: "Repair Steam",
                value: "Restore Steam to its original state.",
                action: StatusAction(
                    label: "Repair",
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .replaceSteam }
            )
            StatusRow(
                title: "Remove Everything",
                value: "Remove NotProton and restore Steam to its original state.",
                action: StatusAction(
                    label: "Remove",
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .removeEverything }
            )
        }
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await status.refresh() }
        }
        .disabled(!status.isIdle)
    }

    private func installAction(prominent: Bool, label: String = "Install") -> StatusAction {
        StatusAction(
            label: label,
            isProminent: prominent,
            help: "Install NotProton into Steam.",
            isEnabled: status.canInstall
        ) {
            Task { await status.requestInstall() }
        }
    }

    @ViewBuilder
    private func steamRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .notInstalled:
            if let content = status.snapshot?.installContent, content.blocksInstallation {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        case .installed, .outdated:
            if let content = status.snapshot?.installContent, content != .unchecked {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        default:
            deploymentRow(deployment, payload: payload)
        }
    }

    @ViewBuilder
    private func installedContentRow(_ content: DeploymentContent.Status, deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch content {
        case .unchecked, .current:
            let version: String? = switch deployment {
            case .installed(let version): version
            case .outdated(let deployed, _): deployed
            default: nil
            }
            deploymentRow(.installed(version: version), payload: payload)
        case .newerInstalled:
            StatusRow(title: "NotProton", value: "A newer build is installed.", tone: .neutral,
                      detail: "Use the newer NotProton app to update or repair the installed files.")
        case .unavailable(let reason):
            StatusRow(title: "NotProton", value: "Could not check installed files.", tone: .warning, detail: reason)
        case .update(let files):
            StatusRow(title: "NotProton", value: "Update available.", tone: .warning,
                      detail: "This app includes newer files than those installed for Steam.",
                      action: installAction(prominent: true, label: "Update"))
                .help(files.joined(separator: "\n"))
        case .repair(let files):
            StatusRow(title: "NotProton", value: "Installed files differ from this build.", tone: .warning,
                      detail: "Restore the files included with this app.",
                      action: installAction(prominent: true, label: "Repair"))
                .help(files.joined(separator: "\n"))
        case .unrecorded(let files):
            StatusRow(title: "NotProton", value: "Update available.", tone: .warning,
                      detail: "This app includes updated files for Steam.",
                      action: installAction(prominent: true, label: "Update"))
                .help(files.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func deploymentRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .steamMissing:
            StatusRow(title: "NotProton", value: "Steam not found.", tone: .bad)
        case .notInstalled:
            StatusRow(
                title: "NotProton",
                value: "Not installed.",
                tone: .neutral,
                action: installAction(prominent: true)
            )
        case .installed(let version):
            if payload.isComplete {
                StatusRow(
                    title: "NotProton",
                    value: "Installed" + (version.map { " (\($0))" } ?? ""),
                    tone: .ok
                )
            } else {
                StatusRow(
                    title: "NotProton",
                    value: "Installed, but not for this account.",
                    tone: .warning,
                    detail: "Steam is set up for NotProton, but this account is missing its "
                        + "components. Install to add them.",
                    action: installAction(prominent: true)
                )
            }
        case .outdated(_, let bundled):
            StatusRow(
                title: "NotProton",
                value: "Update available (\(bundled)).",
                tone: .warning,
                action: installAction(prominent: true)
            )
        }
    }

    // Another tool's library in Steam's insert, which NotProton loads beside.
    @ViewBuilder
    private func sharedInsertRow(_ others: [String], steam: SteamDeployment) -> some View {
        if !others.isEmpty {
            let names = others.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ")
            StatusRow(
                title: "Shared with",
                value: names,
                tone: .info,
                detail: steam == .notInstalled
                    ? "NotProton is added beside it when you install."
                    : "NotProton loads beside it. If that tool rewrites Steam's settings without "
                        + "NotProton, install again."
            )
        }
    }

    private func updateBlockRow(_ blocked: Bool) -> some View {
        StatusRow(
            title: "Block Steam client updates",
            value: blocked
                ? "The Steam client will not update itself."
                : "A Steam client update may break NotProton.",
            toggle: blockUpdates
        )
        .disabled(!status.isIdle)
        .help("Steam client updates may break NotProton.")
    }

    private var blockUpdates: Binding<Bool> {
        Binding(
            get: { status.snapshot?.updateBlocked ?? false },
            set: { wanted in
                if wanted {
                    status.pendingConfirmation = .blockUpdates
                } else {
                    Task { await status.setUpdateBlock(false) }
                }
            }
        )
    }

    @ViewBuilder
    private func wineSection(_ snapshot: StatusSnapshot) -> some View {
        let rows = status.wineRows
        if rows.isEmpty {
            StatusRow(
                title: "MnC Wine",
                value: "No release found. Supported: \(SupportedRunners.versionList).",
                tone: .bad,
                detail: "Expected at \(SupportPaths.defaultArchive.path(percentEncoded: false))"
            )
        }
        let tools = SupportedRunners.tools(for: snapshot.installedRunners)
        ForEach(rows) { row in
            StatusRow(
                title: row.title,
                value: wineValue(row),
                tone: wineTone(row),
                detail: wineDetail(row, tools: tools),
                trailing: row.copy == .ready ? buildSize(row.buildID) : nil,
                action: wineAction(row, prominent: snapshot.runner == .none),
                menu: wineMenu(row)
            )
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(-6)
                    .opacity(status.highlightedRow == row.id ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.3), value: status.highlightedRow == row.id)
            .id(row.id)
        }
        if !snapshot.missingLibraries.isEmpty {
            StatusRow(
                title: "x86_64 libraries",
                value: "Missing \(snapshot.missingLibraries.map(\.purpose).joined(separator: ", ")).",
                tone: .warning,
                detail: "Install them with Intel Homebrew (arch -x86_64 /usr/local/bin/brew install "
                    + "freetype gnutls), or set up MacNdCheese once so its deps folder has them."
            )
        }
        if case .ready = snapshot.runner, !snapshot.payload.missing(origin: .patched).isEmpty {
            StatusRow(
                title: "Compatibility Tool",
                value: "Patched components are missing.",
                tone: .warning,
                action: StatusAction(
                    label: "Repair",
                    isProminent: true,
                    help: "Set up the compatibility tool again.",
                    isEnabled: status.isIdle && status.setupSource != nil
                ) { Task { await status.requestCompatibilityTool() } }
            )
        }
    }

    private func wineValue(_ row: WineRow) -> String {
        if let hash = row.unsupportedHash {
            return "Unknown build \(hash) (supported: \(SupportedRunners.versionList))"
        }
        let build = SupportedRunners.displayVersion(forID: row.buildID)
        switch row.copy {
        case .ready: return build
        case .none: return build + ", not set up"
        case .unpatched: return build + ", not patched"
        case .damaged: return build + ", copy damaged"
        case .unsupported: return build + ", not supported"
        }
    }

    private func wineTone(_ row: WineRow) -> StatusTone {
        if row.unsupportedHash != nil { return .neutral }
        switch row.copy {
        case .none: return .neutral
        case .ready: return .ok
        case .unpatched, .damaged, .unsupported: return .warning
        }
    }

    private func wineDetail(_ row: WineRow, tools: [InstalledTool]) -> String? {
        var lines: [String] = []
        if row.copy == .ready || row.copy == .unpatched {
            let names = tools.filter { $0.build == row.buildID }.map(\.display)
            lines.append(contentsOf: names)
            if let pack = MncWineSource.packVersion(root: SupportPaths.clonedRoot(forBuild: row.buildID)) {
                lines.append(pack)
            }
        }
        if let archive = row.archive {
            lines.append(archive.file.path(percentEncoded: false))
        } else if row.copy != .unsupported {
            lines.append("Release tarball not found.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func wineAction(_ row: WineRow, prominent: Bool) -> StatusAction? {
        let archive = row.archive
        switch row.copy {
        case .none where row.canSetUp:
            return StatusAction(
                label: "Set Up",
                isProminent: prominent,
                help: "Unpack \(row.title) and set up its compatibility tool.",
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: archive) } }
        case .unpatched where row.canSetUp, .damaged where row.canSetUp:
            return StatusAction(
                label: "Repair",
                isProminent: true,
                help: "Unpack \(row.title) again.",
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: archive) } }
        case .unsupported:
            return removeCopyAction(row.buildID, label: "Remove\u{2026}")
        default:
            return nil
        }
    }

    private func wineMenu(_ row: WineRow) -> [StatusAction] {
        var items: [StatusAction] = []
        let archive = row.archive
        if row.copy == .ready {
            items.append(StatusAction(
                label: "Reinstall",
                help: "Unpack \(row.title) again.",
                isEnabled: status.canInstall && row.canSetUp
            ) { Task { await status.requestCompatibilityTool(from: archive, replacingExisting: true) } })
        }
        let shown = archive?.file
            ?? (row.copy == .none ? nil : SupportPaths.runnerRoot(forBuild: row.buildID))
        if let shown {
            items.append(StatusAction(label: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            })
        }
        if [.ready, .unpatched, .damaged].contains(row.copy) {
            var remove = removeCopyAction(row.buildID, label: "Remove Copy\u{2026}")
            remove.startsGroup = true
            items.append(remove)
        }
        if let archive, row.isManual {
            items.append(StatusAction(
                label: "Remove from List",
                isEnabled: status.isIdle,
                startsGroup: !items.contains(where: \.startsGroup)
            ) { Task { await status.removeFromList(archive) } })
        }
        return items
    }

    private func buildSize(_ build: String) -> String? {
        guard let runner = status.runnerSizes[build] else { return nil }
        let flavors = SupportedRunners.build(id: build)?.tools.map(\.flavor) ?? []
        return Self.sizeText(runner: runner, templates: status.templateSizes[build] ?? [:], flavors: flavors)
    }

    nonisolated static func sizeText(runner: Int64, templates: [CompatTool.Flavor: Int64], flavors: [CompatTool.Flavor]) -> String {
        let lines: [String]
        if flavors.count > 1 {
            lines = flavors.compactMap { flavor in
                guard let bytes = templates[flavor], bytes > 0 else { return nil }
                return "\(flavor.name) templates \(bytes.formatted(.byteCount(style: .file)))"
            }
        } else {
            let bytes = templates.values.reduce(0, +)
            lines = bytes > 0 ? ["Templates \(bytes.formatted(.byteCount(style: .file)))"] : []
        }
        return (["Runner \(runner.formatted(.byteCount(style: .file)))"] + lines).joined(separator: "\n")
    }

    private func removeCopyAction(_ build: String, label: String) -> StatusAction {
        StatusAction(
            label: label,
            role: .destructive,
            help: "Delete NotProton's copy of this build.",
            isEnabled: status.canInstall
        ) {
            status.requestBuildRemoval(build)
        }
    }

    private func fetchAction() -> StatusAction {
        StatusAction(
            label: "Fetch Valve Binaries",
            isProminent: true,
            help: "Download missing Valve binaries.",
            isEnabled: status.canInstall
        ) { Task { await status.fetchValveBinaries() } }
    }

    @ViewBuilder
    private func componentsSection(_ payload: PayloadState) -> some View {
        if let problem = payload.manifestProblem {
            Section("NotProton Components") {
                StatusRow(title: "Components", value: "Component list unreadable.", tone: .bad, detail: problem)
            }
        } else if payload.isComplete {
            Section("NotProton Components") {
                StatusRow(
                    title: "Components", value: "Ready.", tone: .ok,
                    trailing: status.bridgeCopyBytes > 0
                        ? "Copies on other drives \(status.bridgeCopyBytes.formatted(.byteCount(style: .file)))" : nil
                )
            }
        } else if payload.isEmpty {
            Section("NotProton Components") {
                StatusRow(title: "Components", value: "Not yet deployed.", tone: .neutral)
            }
        } else {
            Section("NotProton Components") {
                if !payload.missing.isEmpty {
                    let names = payload.missing.map {
                        URL(filePath: $0.path).lastPathComponent
                    }.joined(separator: ", ")
                    StatusRow(
                        title: "Missing.",
                        value: names,
                        tone: .bad,
                        action: payload.missing.contains(where: { $0.origin.isFetchable })
                            ? fetchAction() : nil
                    )
                }
                if !payload.overlayShimPresent {
                    StatusRow(title: "Overlay shim", value: "Missing.", tone: .bad)
                }
                if payload.signatureDatabase == nil {
                    StatusRow(title: "Signature database", value: "Missing.", tone: .bad)
                }
            }
        }
    }
}
