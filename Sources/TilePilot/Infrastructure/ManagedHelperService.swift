import Darwin
import Foundation

struct ManagedHelperOperationResult: Sendable {
    let installState: ManagedHelperInstallState?
    let commandLogs: [CommandLogEntry]
    let successMessage: String?
    let errorMessage: String?
}

final class ManagedHelperService: @unchecked Sendable {
    static let shared = ManagedHelperService()

    private let runner = CommandRunner()

    private let systemFallbackSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    func bundledManifest(bundle: Bundle = .main) -> BundledHelperManifest? {
        guard let url = bundledManifestURL(bundle: bundle),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BundledHelperManifest.self, from: data)
    }

    func bundledHelperURL(for helper: ManagedHelperKind, bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helper.executableName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func managedHelperURL(for helper: ManagedHelperKind) -> URL {
        managedBinDirectory().appendingPathComponent(helper.executableName)
    }

    func hasManagedHelperInstall() -> Bool {
        if let state = loadInstallState(), !state.helpers.isEmpty {
            return true
        }
        return ManagedHelperKind.allCases.contains { FileManager.default.isExecutableFile(atPath: managedHelperURL(for: $0).path) }
    }

    func resolvedHelperURL(for helper: ManagedHelperKind, bundle: Bundle = .main) -> URL? {
        let managedURL = managedHelperURL(for: helper)
        if FileManager.default.isExecutableFile(atPath: managedURL.path) {
            return managedURL
        }
        return externalHelperURL(for: helper)
    }

    func helperCommand(_ helper: ManagedHelperKind, arguments: [String], timeout: TimeInterval = 2.0) -> ShellCommand {
        if let url = resolvedHelperURL(for: helper) {
            return ShellCommand(url.path, arguments, timeout: timeout)
        }
        return ShellCommand("/usr/bin/env", [helper.executableName] + arguments, timeout: timeout)
    }

    func environmentWithManagedHelpers(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let systemPreferred = "/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/sbin:/usr/local/sbin"
        let existingPath = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let managedBin = managedBinDirectory().path
        let pathParts = ([managedBin, systemPreferred] + existingPath.split(separator: ":").map(String.init))
        env["PATH"] = uniquePathComponents(from: pathParts).joined(separator: ":")
        return env
    }

    func loadInstallState() -> ManagedHelperInstallState? {
        let url = installStateURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ManagedHelperInstallState.self, from: data)
    }

    func installBundledHelpers(bundle: Bundle = .main, startServicesAfterInstall: Bool? = nil) async -> ManagedHelperOperationResult {
        guard let manifest = bundledManifest(bundle: bundle) else {
            return ManagedHelperOperationResult(
                installState: loadInstallState(),
                commandLogs: [],
                successMessage: nil,
                errorMessage: "This TilePilot build does not include bundled helper binaries."
            )
        }

        do {
            try ensureManagedDirectories()
            let previousState = loadInstallState()
            var installed: [ManagedInstalledHelper] = []
            for definition in manifest.helpers {
                guard let bundledURL = bundledHelperURL(for: definition.helper, bundle: bundle) else {
                    return ManagedHelperOperationResult(
                        installState: loadInstallState(),
                        commandLogs: [],
                        successMessage: nil,
                        errorMessage: "Missing bundled helper binary for \(definition.helper.displayName)."
                    )
                }
                let destination = managedHelperURL(for: definition.helper)
                try copyExecutableAtomically(from: bundledURL, to: destination)
                installed.append(
                    ManagedInstalledHelper(
                        helper: definition.helper,
                        version: definition.version,
                        architecture: definition.architecture,
                        installedPath: destination.path,
                        sourceChecksumSHA256: definition.checksumSHA256
                    )
                )
            }

            let requestedServiceStart = startServicesAfterInstall ?? shouldBootstrapManagedServicesAfterInstall(previousState: previousState)
            // Protect every install/upgrade caller, including legacy state that still
            // has TilePilot LaunchAgent files. Those agents must not be loaded until
            // the user has explicitly started window control once.
            let shouldStartServices = requestedServiceStart && HelperStartConsentPolicy.allowsAutomaticStart()
            let launchAgentLogs: [CommandLogEntry]
            let launchAgentsInstalled: Bool
            let servicesBootstrapped: Bool
            if shouldStartServices {
                launchAgentLogs = try await installOrUpdateLaunchAgents()
                launchAgentsInstalled = true
                servicesBootstrapped = launchAgentLogs.allSatisfy { $0.errorType == .none && ($0.exitStatus ?? 0) == 0 }
            } else {
                launchAgentLogs = []
                launchAgentsInstalled = false
                servicesBootstrapped = false
            }
            let installState = ManagedHelperInstallState(
                updatedAt: Date(),
                helpers: installed.sorted { $0.helper.rawValue < $1.helper.rawValue },
                launchAgentsInstalled: launchAgentsInstalled,
                servicesBootstrapped: servicesBootstrapped
            )
            try writeInstallState(installState)
            return ManagedHelperOperationResult(
                installState: installState,
                commandLogs: launchAgentLogs,
                successMessage: installState.servicesBootstrapped
                    ? "Installed and started TilePilot window-control components."
                    : "Installed TilePilot's local copies of yabai and skhd. Start window control when you are ready.",
                errorMessage: nil
            )
        } catch {
            return ManagedHelperOperationResult(
                installState: loadInstallState(),
                commandLogs: [],
                successMessage: nil,
                errorMessage: "TilePilot could not install its local yabai/skhd copies: \(error.localizedDescription)"
            )
        }
    }

    func detectExistingExternalHelpers() async -> [ExistingHelperInstall] {
        guard !hasManagedHelperInstall() else { return [] }

        var installs: [ExistingHelperInstall] = []
        for helper in ManagedHelperKind.allCases {
            let binaryURL = externalHelperURL(for: helper)
            let processResult = await runner.run(.init("/usr/bin/pgrep", ["-x", helper.executableName], timeout: 1.0))
            let running = processResult.isSuccess
            let homebrewAgent = homebrewLaunchAgentURL(for: helper)
            let externalAgent = externalLaunchAgentURL(for: helper)
            let source: ExistingHelperInstallSource
            if homebrewAgent != nil || isHomebrewPath(binaryURL?.path) {
                source = .homebrew
            } else if externalAgent != nil {
                source = .launchAgent
            } else {
                source = .binaryOnly
            }

            guard binaryURL != nil || running || homebrewAgent != nil || externalAgent != nil else { continue }

            installs.append(
                ExistingHelperInstall(
                    helper: helper,
                    binaryPath: binaryURL?.path,
                    runningExternally: running,
                    source: source,
                    launchAgentPath: homebrewAgent?.path ?? externalAgent?.path
                )
            )
        }

        return installs
    }

    func installBundledHelpersReplacingExternalServices(bundle: Bundle = .main) async -> ManagedHelperOperationResult {
        let existingInstalls = await detectExistingExternalHelpers()
        let stopLogs = await stopExternalHelperServices(existingInstalls)
        let installResult = await installBundledHelpers(bundle: bundle, startServicesAfterInstall: true)
        let successMessage: String?
        if installResult.errorMessage == nil, !existingInstalls.isEmpty {
            successMessage = "Stopped external yabai/skhd services and installed TilePilot-managed components."
        } else {
            successMessage = installResult.successMessage
        }

        return ManagedHelperOperationResult(
            installState: installResult.installState,
            commandLogs: stopLogs + installResult.commandLogs,
            successMessage: successMessage,
            errorMessage: installResult.errorMessage
        )
    }

    func startManagedServices() async -> ManagedHelperOperationResult {
        do {
            try ensureManagedDirectories()
            let logs = try await installOrUpdateLaunchAgents()
            let previous = loadInstallState()
            let installState = ManagedHelperInstallState(
                updatedAt: Date(),
                helpers: previous?.helpers ?? [],
                launchAgentsInstalled: true,
                servicesBootstrapped: logs.allSatisfy { $0.errorType == .none && ($0.exitStatus ?? 0) == 0 }
            )
            try writeInstallState(installState)
            return ManagedHelperOperationResult(
                installState: installState,
                commandLogs: logs,
                successMessage: installState.servicesBootstrapped ? "Started TilePilot window-control services." : nil,
                errorMessage: installState.servicesBootstrapped ? nil : "TilePilot could not start yabai/skhd. macOS may require Accessibility approval for the helper named in the system prompt; approve that entry, then try again."
            )
        } catch {
            return ManagedHelperOperationResult(
                installState: loadInstallState(),
                commandLogs: [],
                successMessage: nil,
                errorMessage: "TilePilot could not start window-control services: \(error.localizedDescription)"
            )
        }
    }

    func binaryStatusItem(for helper: ManagedHelperKind) async -> SetupCheckItem {
        let result = await runner.run(helperCommand(helper, arguments: ["--version"], timeout: 1.5))
        if result.isSuccess {
            let version = cleanedLine(from: result.stdout) ?? "Detected"
            let source = sourceLabel(for: helper)
            return SetupCheckItem(id: "\(helper.rawValue)-binary", title: helper.displayName, state: .installed, detail: "\(version) (\(source))")
        }
        return SetupCheckItem(id: "\(helper.rawValue)-binary", title: helper.displayName, state: .missing, detail: "\(helper.displayName) is not installed yet.")
    }

    func serviceStatusItem(for helper: ManagedHelperKind) async -> SetupCheckItem {
        let processResult = await runner.run(.init("/usr/bin/pgrep", ["-x", helper.executableName], timeout: 1.0))
        let plistURL = launchAgentURL(for: helper)
        let hasLaunchAgent = FileManager.default.fileExists(atPath: plistURL.path)
        let hasManagedBinary = FileManager.default.isExecutableFile(atPath: managedHelperURL(for: helper).path)
        if processResult.isSuccess {
            let detail = hasLaunchAgent ? "Running from TilePilot-managed LaunchAgent." : "Running from an external install."
            return SetupCheckItem(id: "helper-service-\(helper.rawValue)", title: "\(helper.displayName) service", state: .installed, detail: detail)
        }
        if hasLaunchAgent {
            return SetupCheckItem(id: "helper-service-\(helper.rawValue)", title: "\(helper.displayName) service", state: .warning, detail: "Installed but not running.")
        }
        if hasManagedBinary {
            return SetupCheckItem(
                id: "helper-service-\(helper.rawValue)",
                title: "\(helper.displayName) service",
                state: .warning,
                detail: "Installed by TilePilot but not started yet. Start window control when you are ready for any macOS permission prompt."
            )
        }
        return SetupCheckItem(id: "helper-service-\(helper.rawValue)", title: "\(helper.displayName) service", state: .missing, detail: "Not running yet.")
    }

    func bundledHelpersAvailable(bundle: Bundle = .main) -> Bool {
        guard let manifest = bundledManifest(bundle: bundle) else { return false }
        return manifest.helpers.allSatisfy { bundledHelperURL(for: $0.helper, bundle: bundle) != nil }
    }

    func hasOperationalHelpers() -> Bool {
        resolvedHelperURL(for: .yabai) != nil && resolvedHelperURL(for: .skhd) != nil
    }

    func managedHelpersNeedUpgrade(bundle: Bundle = .main, currentState: ManagedHelperInstallState? = nil) -> Bool {
        guard let manifest = bundledManifest(bundle: bundle) else { return false }
        let state = currentState ?? loadInstallState()
        guard let state, !state.helpers.isEmpty else { return false }

        for definition in manifest.helpers {
            guard let installed = state.helpers.first(where: { $0.helper == definition.helper }) else {
                return true
            }
            guard installed.version == definition.version,
                  installed.architecture == definition.architecture,
                  installed.sourceChecksumSHA256 == definition.checksumSHA256,
                  installed.installedPath == managedHelperURL(for: definition.helper).path,
                  FileManager.default.isExecutableFile(atPath: installed.installedPath) else {
                return true
            }
        }

        return false
    }

    private func externalHelperURL(for helper: ManagedHelperKind) -> URL? {
        let envPath = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in uniquePathComponents(from: systemFallbackSearchPaths + envPath) {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(helper.executableName)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func sourceLabel(for helper: ManagedHelperKind) -> String {
        if FileManager.default.isExecutableFile(atPath: managedHelperURL(for: helper).path) {
            return "managed"
        }
        if let external = externalHelperURL(for: helper) {
            return external.path
        }
        return "missing"
    }

    private func bundledManifestURL(bundle: Bundle) -> URL? {
        bundle.resourceURL?
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("helper-manifest.json")
    }

    private func managedSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TilePilot", isDirectory: true)
    }

    private func managedBinDirectory() -> URL {
        managedSupportDirectory().appendingPathComponent("bin", isDirectory: true)
    }

    private func managedStateDirectory() -> URL {
        managedSupportDirectory().appendingPathComponent("Helpers", isDirectory: true)
    }

    private func managedLogsDirectory() -> URL {
        managedSupportDirectory().appendingPathComponent("Logs", isDirectory: true)
    }

    private func installStateURL() -> URL {
        managedStateDirectory().appendingPathComponent("managed-helper-install-state.json")
    }

    private func launchAgentURL(for helper: ManagedHelperKind) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(helper.launchAgentLabel).plist")
    }

    private func homebrewLaunchAgentURL(for helper: ManagedHelperKind) -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("homebrew.mxcl.\(helper.executableName).plist")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func externalLaunchAgentURL(for helper: ManagedHelperKind) -> URL? {
        let launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: launchAgentsDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }

        return entries.first { url in
            let name = url.lastPathComponent.lowercased()
            return name.contains(helper.executableName) &&
                !name.contains("com.klode.tilepilot.") &&
                name.hasSuffix(".plist")
        }
    }

    private func ensureManagedDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: managedBinDirectory(), withIntermediateDirectories: true)
        try fm.createDirectory(at: managedStateDirectory(), withIntermediateDirectories: true)
        try fm.createDirectory(at: managedLogsDirectory(), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func copyExecutableAtomically(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let tempURL = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        if fm.fileExists(atPath: tempURL.path) {
            try? fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: source, to: tempURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempURL.path)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempURL, to: destination)
    }

    private func installOrUpdateLaunchAgents() async throws -> [CommandLogEntry] {
        try writeLaunchAgents()
        var logs: [CommandLogEntry] = []
        for helper in ManagedHelperKind.allCases {
            let plistPath = launchAgentURL(for: helper).path
            let domain = launchctlDomain()
            let commands = [
                ShellCommand("/bin/launchctl", ["bootout", domain, plistPath], timeout: 2.0),
                ShellCommand("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 2.0),
                ShellCommand("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(helper.launchAgentLabel)"], timeout: 2.0),
            ]
            for command in commands {
                let result = await runner.run(command)
                if command.arguments.first == "bootout", result.errorType != .none {
                    // bootout failing on a not-yet-loaded agent is fine
                    logs.append(makeLog(from: CommandResult(command: result.command, startedAt: result.startedAt, endedAt: result.endedAt, exitStatus: 0, stdout: result.stdout, stderr: "", errorType: .none)))
                } else {
                    logs.append(makeLog(from: result))
                }
            }
        }
        return logs
    }

    private func writeLaunchAgents() throws {
        for helper in ManagedHelperKind.allCases {
            let plist = launchAgentPlist(for: helper)
            try plist.write(to: launchAgentURL(for: helper), atomically: true, encoding: .utf8)
        }
    }

    private func shouldBootstrapManagedServicesAfterInstall(previousState: ManagedHelperInstallState?) -> Bool {
        if previousState?.launchAgentsInstalled == true {
            return true
        }
        return ManagedHelperKind.allCases.contains { helper in
            FileManager.default.fileExists(atPath: launchAgentURL(for: helper).path)
        }
    }

    private func launchAgentPlist(for helper: ManagedHelperKind) -> String {
        let executablePath = managedHelperURL(for: helper).path
        let stdoutPath = managedLogsDirectory().appendingPathComponent("\(helper.rawValue).stdout.log").path
        let stderrPath = managedLogsDirectory().appendingPathComponent("\(helper.rawValue).stderr.log").path
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let path = environmentWithManagedHelpers()["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(helper.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(executablePath))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>WorkingDirectory</key>
            <string>\(xmlEscaped(workingDirectory))</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(xmlEscaped(path))</string>
            </dict>
            <key>StandardOutPath</key>
            <string>\(xmlEscaped(stdoutPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscaped(stderrPath))</string>
        </dict>
        </plist>
        """
    }

    private func launchctlDomain() -> String {
        "gui/\(getuid())"
    }

    private func stopExternalHelperServices(_ installs: [ExistingHelperInstall]) async -> [CommandLogEntry] {
        var logs: [CommandLogEntry] = []
        let domain = launchctlDomain()

        for install in installs {
            if install.source == .homebrew {
                let brewStop = await runner.run(.init("/usr/bin/env", ["brew", "services", "stop", install.helper.executableName], timeout: 12.0))
                logs.append(makeLog(from: brewStop))
            }

            if let launchAgentPath = install.launchAgentPath {
                let bootout = await runner.run(.init("/bin/launchctl", ["bootout", domain, launchAgentPath], timeout: 3.0))
                if bootout.errorType != .none {
                    logs.append(makeLog(from: CommandResult(command: bootout.command, startedAt: bootout.startedAt, endedAt: bootout.endedAt, exitStatus: 0, stdout: bootout.stdout, stderr: "", errorType: .none)))
                } else {
                    logs.append(makeLog(from: bootout))
                }
            }

            let kill = await runner.run(.init("/usr/bin/pkill", ["-x", install.helper.executableName], timeout: 2.0))
            if kill.errorType != .none {
                logs.append(makeLog(from: CommandResult(command: kill.command, startedAt: kill.startedAt, endedAt: kill.endedAt, exitStatus: 0, stdout: kill.stdout, stderr: "", errorType: .none)))
            } else {
                logs.append(makeLog(from: kill))
            }
        }

        return logs
    }

    private func writeInstallState(_ state: ManagedHelperInstallState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: installStateURL(), options: .atomic)
    }

    private func cleanedLine(from output: String) -> String? {
        output
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeLog(from result: CommandResult) -> CommandLogEntry {
        CommandLogEntry(
            id: UUID(),
            command: result.command,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            durationMs: result.durationMs,
            exitStatus: result.exitStatus,
            stdoutSnippet: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description,
            stderrSnippet: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160).description,
            errorType: result.errorType
        )
    }

    private func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func uniquePathComponents(from parts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in parts {
            for piece in raw.split(separator: ":").map(String.init) {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                result.append(trimmed)
            }
        }
        return result
    }

    private func isHomebrewPath(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")
    }
}

func yabaiCommand(_ arguments: [String], timeout: TimeInterval = 2.0) -> ShellCommand {
    ManagedHelperService.shared.helperCommand(.yabai, arguments: arguments, timeout: timeout)
}

func skhdCommand(_ arguments: [String], timeout: TimeInterval = 2.0) -> ShellCommand {
    ManagedHelperService.shared.helperCommand(.skhd, arguments: arguments, timeout: timeout)
}
