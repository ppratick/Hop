import AppKit
import SwiftUI

struct DeploymentConfig: Codable {
    var deviceID: String
    var scheme: String
    var buildID = UUID().uuidString
    var artifactPath = ""
    var developmentTeam: String? = nil
}

func deploymentSigningArguments(_ config: DeploymentConfig) -> [String] {
    guard let team = config.developmentTeam?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty else { return [] }
    return ["DEVELOPMENT_TEAM=" + team]
}

func xcodeContainerArguments(_ project: Project) throws -> [String] {
    guard let path = project.xcode, ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: path).pathExtension) else {
        throw DeviceTrackingError.message("Choose an Xcode project or workspace.")
    }
    return [path.hasSuffix(".xcworkspace") ? "-workspace" : "-project", path]
}

// Called on a worker task; output goes to Hop's support folder, never the project.
func deploymentCommand(_ process: Process, arguments: [String], log: URL, timeout: Double = 900) throws -> Data {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit(); deadline.cancel()
    try data.write(to: log, options: .atomic)
    guard process.terminationStatus == 0 else {
        let tail = String(decoding: data.suffix(1800), as: UTF8.self)
        throw DeviceTrackingError.message("Command failed. " + tail)
    }
    return data
}

func deploymentSchemes(_ project: Project) throws -> [String] {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hop-schemes-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let data = try deploymentCommand(Process(), arguments: ["xcodebuild"] + xcodeContainerArguments(project) + ["-list", "-json", "-disableAutomaticPackageResolution"],
                                     log: temp.appendingPathComponent("schemes.log"), timeout: 60)
    // xcodebuild can print diagnostic text before its JSON.
    let text = String(decoding: data, as: UTF8.self)
    guard let start = text.firstIndex(of: "{"),
          let json = text[start...].data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
          let container = (root["project"] ?? root["workspace"]) as? [String: Any],
          let schemes = container["schemes"] as? [String] else {
        throw DeviceTrackingError.message("Couldn’t read Xcode schemes. Open this project in Xcode to configure a shared app scheme.")
    }
    return schemes.sorted()
}

func builtDeviceApp(in derived: URL, preferredBundle: String?, scheme: String) throws -> URL {
    var apps: [URL] = []
    for configuration in children(derived.appendingPathComponent("Build/Products"))
        where !configuration.lastPathComponent.contains("simulator") {
        for app in children(configuration) where app.pathExtension == "app" {
            if FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path) { apps.append(app) }
        }
    }
    if let preferredBundle {
        let matches = apps.filter { app in
            guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
            return info["CFBundleIdentifier"] as? String == preferredBundle
        }
        if matches.count == 1 { return matches[0] }
    }
    let named = apps.filter { $0.deletingPathExtension().lastPathComponent == scheme }
    if named.count == 1 { return named[0] }
    guard apps.count == 1 else { throw DeviceTrackingError.message("Couldn’t identify one signed device app. Select the app’s scheme in deployment settings.") }
    return apps[0]
}

func validateDeploymentProfile(_ profile: SigningProfile, bundleID: String, deviceID: String) throws {
    guard profile.devices.contains(deviceID), profile.expires > Date() else {
        throw DeviceTrackingError.message("The built app’s signing profile is expired or doesn’t include the selected device.")
    }
    guard profile.bundleID == bundleID || (profile.bundleID.hasSuffix("*") && bundleID.hasPrefix(String(profile.bundleID.dropLast()))) else {
        throw DeviceTrackingError.message("The app identifier doesn’t match its signing profile.")
    }

}

func installationRecord(project: Project, deviceID: String, app: URL) throws -> SigningRecord {
    let profile = try loadSigningProfile(app)
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
          let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
          let bundleID = info["CFBundleIdentifier"] as? String else {
        throw DeviceTrackingError.message("The built app has no bundle identifier.")
    }
    try validateDeploymentProfile(profile, bundleID: bundleID, deviceID: deviceID)
    return SigningRecord(projectID: project.id, deviceID: deviceID, bundleID: bundleID, installedAt: Date(),
                         expiresAt: profile.expires, profileBased: true, artifactPath: app.path, installedByHop: true)
}

extension Store {
    var deploymentBusy: Bool { deploymentProjectID != nil }
    func deploymentAvailable(_ deviceID: String) -> Bool {
        deviceID == localMacDeviceID || discoveredDevices.contains { $0.id == deviceID && ["connected", "disconnected"].contains($0.state) }
    }
    func deploymentDeviceName(_ deviceID: String) -> String {
        deviceID == localMacDeviceID ? "This Mac" : disk.devices.first { $0.id == deviceID }?.name ?? "Selected device"
    }
    func configureDeployment(_ project: Project) {
        let previousPage = projectPage
        let sameProject = settingsProject == project.id && !settingsDevices
        showSettings?(project.id)
        if sameProject { projectPage = previousPage }
        deploymentSetupProject = project
    }
    func deploy(_ project: Project) {
        guard !deploymentBusy, let config = disk.deployments[project.id] else { return }
        deploymentCompletionTokens[project.id] = nil
        deploymentProjectID = project.id
        deploymentStatus[project.id] = "Checking device…"
        Task { [self] in
            do {
                if !config.isMac {
                    let found = try await Task.detached { try discoverHopDevices() }.value
                    discoveredDevices = found; devicesCheckedAt = Date()
                    guard found.contains(where: { $0.id == config.deviceID && ["connected", "disconnected"].contains($0.state) }) else {
                        throw DeviceTrackingError.message("Connect the selected device and unlock it, then try again.")
                    }
                }
                let base = support.appendingPathComponent("DeviceBuilds/" + config.buildID)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let log = base.appendingPathComponent("build.log")
                deploymentLogs[project.id] = log
                deploymentStatus[project.id] = "Building & updating signing…"
                let process = Process(); deploymentProcess = process
                let args = ["xcodebuild"] + (try xcodeContainerArguments(project)) +
                    ["-scheme", config.scheme, "-configuration", "Debug", "-destination", deploymentDestination(config),
                     "-derivedDataPath", base.appendingPathComponent("DerivedData").path,
                     "-allowProvisioningUpdates"] + (config.isMac ? [] : ["-allowProvisioningDeviceRegistration"]) + deploymentSigningArguments(config)
                _ = try await Task.detached { try deploymentCommand(process, arguments: args + ["build"], log: log) }.value
                let record: SigningRecord
                if config.isMac {
                    let settingsProcess = Process(); deploymentProcess = settingsProcess
                    let settings = try await Task.detached {
                        try deploymentCommand(settingsProcess, arguments: args + ["-showBuildSettings", "-json"],
                                              log: base.appendingPathComponent("settings.log"), timeout: 90)
                    }.value
                    let app = try macBuildProduct(settings, scheme: config.scheme)
                    disk.deployments[project.id]?.artifactPath = app.path; save()
                    deploymentStatus[project.id] = "Installing…"
                    let verify = Process(); deploymentProcess = verify
                    let installLog = base.appendingPathComponent("install.log")
                    deploymentLogs[project.id] = installLog
                    _ = try await Task.detached {
                        try deploymentCommand(verify, arguments: ["codesign", "--verify", "--deep", "--strict", app.path], log: installLog, timeout: 60)
                    }.value
                    let installed = try await Task.detached {
                        try installMacApp(app, in: macInstallationDirectory(for: app))
                    }.value
                    record = SigningRecord(projectID: project.id, deviceID: config.deviceID, bundleID: try macAppBundleID(installed),
                                           installedAt: Date(), expiresAt: .distantFuture, profileBased: false,
                                           artifactPath: installed.path, installedByHop: true)
                } else {
                    record = try await Task.detached {
                        let app = try builtDeviceApp(in: base.appendingPathComponent("DerivedData"), preferredBundle: xcodeAppBundleID(project), scheme: config.scheme)
                        return try installationRecord(project: project, deviceID: config.deviceID, app: app)
                    }.value
                    // A successful build is useful even when subsequent installation fails.
                    disk.deployments[project.id]?.artifactPath = record.artifactPath
                    save()
                    deploymentStatus[project.id] = "Installing…"
                    let installer = Process(); deploymentProcess = installer
                    let installLog = base.appendingPathComponent("install.log")
                    deploymentLogs[project.id] = installLog
                    _ = try await Task.detached {
                        try deploymentCommand(installer, arguments: ["devicectl", "device", "install", "app", "--device", config.deviceID,
                                                                    record.artifactPath, "--timeout", "120"], log: installLog, timeout: 140)
                    }.value
                }
                var installed = record; installed.installedAt = Date()
                disk.signingRecords.removeAll { $0.projectID == project.id && $0.deviceID == config.deviceID }
                disk.signingRecords.append(installed); save()
                deploymentStatus[project.id] = "Installed successfully"
                let token = UUID()
                deploymentCompletionTokens[project.id] = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.deploymentCompletionTokens[project.id] == token else { return }
                    withAnimation(.easeOut(duration: 0.2)) { self.deploymentStatus[project.id] = nil }
                    self.deploymentCompletionTokens[project.id] = nil
                }
            } catch {
                deploymentStatus[project.id] = "Installation needs attention"
                message = error.localizedDescription
            }
            deploymentProcess = nil; deploymentProjectID = nil
        }
    }
}

struct ProjectDeploymentActions: View {
    @ObservedObject var store: Store
    let project: Project
    let compact: Bool
    var statusOnly = false
    @State private var localProfile: SigningProfile?
    @State private var showingDetails = false
    var config: DeploymentConfig? { store.disk.deployments[project.id] }
    var isMac: Bool { config?.isMac ?? (project.platforms == ["macOS"]) }
    var record: SigningRecord? {
        store.disk.signingRecords.first { $0.projectID == project.id && $0.deviceID == config?.deviceID && $0.installedByHop == true }
    }
    var displayRecord: SigningRecord? {
        if let record { return record }
        guard let config, let localProfile else { return nil }
        return SigningRecord(projectID: project.id, deviceID: config.deviceID, bundleID: localProfile.bundleID,
                             installedAt: .distantPast, expiresAt: localProfile.expires, profileBased: true,
                             artifactPath: config.artifactPath)
    }
    var body: some View {
        Group {
            if statusOnly {
                signingStatus
            } else if compact {
                compactActions
            } else {
                details
            }
        }
        .task(id: (config?.artifactPath ?? "") + "|" + (config?.deviceID ?? "")) {
            localProfile = nil
            if let config, !config.isMac, !config.artifactPath.isEmpty {
                let path = config.artifactPath
                let profile = await Task.detached { try? loadSigningProfile(URL(fileURLWithPath: path)) }.value
                if !Task.isCancelled, let profile, profile.devices.contains(config.deviceID) { localProfile = profile }
            }
            if !isMac && !statusOnly && (store.devicesCheckedAt == nil || Date().timeIntervalSince(store.devicesCheckedAt!) > 120) { store.discoverDevices() }
        }
    }
    private var signingStatus: some View {
        Group {
            if let displayRecord {
                TimelineView(.periodic(from: .now, by: 60)) { tick in
                    Text(displayRecord.remaining(at: tick.date))
                        .foregroundStyle(displayRecord.tint)
                }
                .help(!displayRecord.profileBased ? "Installed at " + displayRecord.artifactPath : (record == nil ? "Local build profile; installation not verified. " : "Installed app signing. ") +
                      "Expires " + displayRecord.expiresAt.formatted(date: .abbreviated, time: .shortened))
            }
            else {
                Text(isMac ? "Not installed by Hop" : "Expiry unknown").foregroundStyle(.secondary)
                    .help(isMac ? "Build and install this app on your Mac." : "Build and install to record the app’s signing expiration.")
            }
        }.lineLimit(1)
    }
    private var compactActions: some View {
        HStack(spacing: 7) {
            if store.deploymentProjectID == project.id {
                ProgressView().controlSize(.mini)
                    .help(store.deploymentStatus[project.id] ?? "Building…")
            } else {
                Button {
                    if config != nil { store.deploy(project) }
                    else { store.configureDeployment(project) }
                } label: {
                    Text("Build & Install").fixedSize()
                }
                .buttonStyle(.borderless)
                .disabled(store.deploymentBusy || (config.map { !store.deploymentAvailable($0.deviceID) } ?? false))
                .help(config.map { config in
                    let device = store.deploymentDeviceName(config.deviceID)
                    return store.deploymentAvailable(config.deviceID) ? "Build & install on " + device : "Connect " + device + " to install"
                } ?? "Choose device & scheme to build and install")
            }
            Button { showingDetails.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Device, signing & installation details")
            .accessibilityLabel("Device, signing & installation details")
            .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
                ProjectDeploymentActions(store: store, project: project, compact: false)
                    .padding(16).frame(width: 320)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.blue)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if displayRecord == nil && !isMac {
                Text("Expiry unknown").font(.caption).foregroundStyle(.secondary)
                    .help("Build and install to record the app’s signing expiration.")
            }
            if let config {
                HStack(spacing: 8) {
                    Image(systemName: config.isMac ? "desktopcomputer" : store.disk.devices.first(where: { $0.id == config.deviceID })?.symbol ?? "iphone")
                        .foregroundStyle(.blue).frame(width: compact ? 20 : 28, height: compact ? 22 : 30)
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.deploymentDeviceName(config.deviceID))
                            .fontWeight(.medium).lineLimit(1)
                        if !compact { Text(config.scheme).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 2)
                    if let displayRecord {
                        TimelineView(.periodic(from: .now, by: 60)) { tick in
                            Text(displayRecord.remaining(at: tick.date))
                                .font(.system(size: compact ? 9 : 11, weight: .medium))
                                .foregroundStyle(displayRecord.tint)
                        }.help(displayRecord.profileBased ? "Expires " + displayRecord.expiresAt.formatted(date: .abbreviated, time: .shortened) : "Installed at " + displayRecord.artifactPath)
                    }
                    Button { store.configureDeployment(project) } label: {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.borderless).help("Change device or scheme")
                        .accessibilityLabel("Change device or scheme")
                }
                if store.deploymentProjectID == project.id {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(store.deploymentStatus[project.id] ?? "Building…").foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                } else {
                    HStack(spacing: 10) {
                        Button(store.deploymentAvailable(config.deviceID) ? "Build & Install" : "Connect device") {
                            store.deploy(project)
                        }.buttonStyle(.bordered).tint(.blue).controlSize(.small)
                            .disabled(!store.deploymentAvailable(config.deviceID) || store.deploymentBusy)
                        Spacer(minLength: 0)
                    }
                    if let displayRecord, displayRecord.profileBased {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Expires " + displayRecord.expiresAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        if record == nil {
                            Text("Local build profile · installation not verified").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    if config.isMac {
                        Text("Quit and reopen running apps to use the installed update.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let record {
                            Button("Show installed app") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.artifactPath)]) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    if let log = store.deploymentLogs[project.id] {
                        HStack {
                            Spacer()
                            Button { NSWorkspace.shared.open(log) } label: { Label("View logs", systemImage: "doc.text") }
                                .buttonStyle(.borderless).font(.system(size: 10))
                        }
                    }
                    if let status = store.deploymentStatus[project.id] {
                        Label(status, systemImage: status == "Installed successfully" ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(status == "Installed successfully" ? Color.green : Color.orange)
                            .font(.system(size: 10)).transition(.opacity)
                    }
                }
            } else {
                Button { store.configureDeployment(project) } label: {
                    Text("Build & Install…")
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: compact ? 112 : 150, minHeight: compact ? 20 : 24)
                        .padding(.horizontal, compact ? 5 : 8)
                        .foregroundStyle(.blue)
                        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
        }
        .font(.system(size: compact ? 10 : 12))

    }
}

struct DeploymentSetup: View {
    @ObservedObject var store: Store
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = ""
    @State private var scheme = ""
    @State private var schemes: [String] = []
    @State private var developmentTeam = ""
    @State private var loading = true
    @State private var error = ""
    @State private var detectedArtifact = ""
    var supportsMac: Bool { project.platforms.contains("macOS") }
    var macOnly: Bool { project.platforms == ["macOS"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Build & Install").font(.title2.bold())
            Text(store.name(project)).foregroundStyle(.secondary)
            Picker("Device", selection: $deviceID) {
                Text("Choose a device").tag("")
                if supportsMac { Text("This Mac").tag(localMacDeviceID) }
                if !macOnly { ForEach(store.disk.devices) { Text($0.name).tag($0.id) } }
            }
            if store.disk.devices.isEmpty && !supportsMac {
                Text("Enable a device in Settings → Devices first.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("App scheme", selection: $scheme) {
                Text("Choose a scheme").tag("")
                ForEach(schemes, id: \.self) { Text($0).tag($0) }
            }
            TextField("Development team ID (optional)", text: $developmentTeam)
            Text("Leave blank to use the project’s signing team. Applies to the app and its extensions.")
                .font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView().controlSize(.small) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            Text(deviceID == localMacDeviceID ? "Builds for this Mac and installs in Applications. Quit and reopen running apps to use updates." : "Each build lets Xcode update signing automatically, then installs the app and records the actual profile expiration.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    var config = store.disk.deployments[project.id] ?? DeploymentConfig(deviceID: deviceID, scheme: scheme)
                    let team = developmentTeam.trimmingCharacters(in: .whitespacesAndNewlines)
                    if config.deviceID != deviceID || config.scheme != scheme || (config.developmentTeam ?? "") != team {
                        config = DeploymentConfig(deviceID: deviceID, scheme: scheme)
                    }
                    config.developmentTeam = team.isEmpty ? nil : team
                    if config.artifactPath.isEmpty && !config.isMac { config.artifactPath = detectedArtifact }
                    store.disk.deployments[project.id] = config
                    store.save(); dismiss()
                }.buttonStyle(.borderedProminent).disabled(deviceID.isEmpty || !schemes.contains(scheme) || loading || store.deploymentBusy)
            }
        }.padding(24).frame(width: 470)
        .task {
            if let config = store.disk.deployments[project.id] {
                deviceID = config.deviceID; scheme = config.scheme; developmentTeam = config.developmentTeam ?? ""
            }
            else if supportsMac { deviceID = localMacDeviceID }
            else if store.disk.devices.count == 1 { deviceID = store.disk.devices[0].id }
            do {
                schemes = try await Task.detached { try deploymentSchemes(project) }.value
                if scheme.isEmpty {
                    let name = URL(fileURLWithPath: project.xcode ?? "").deletingPathExtension().lastPathComponent
                    if schemes.contains(name) { scheme = name }
                    else if schemes.count == 1 { scheme = schemes[0] }
                }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
        .task(id: deviceID + "|" + scheme) {
            guard !deviceID.isEmpty, deviceID != localMacDeviceID, !scheme.isEmpty else { detectedArtifact = ""; return }
            let device = deviceID
            let selectedScheme = scheme
            let artifact = await Task.detached {
                guard let bundleID = xcodeAppBundleID(project) else { return "" }
                let derived = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData")
                for folder in children(derived).prefix(100) {
                    if let app = try? builtDeviceApp(in: folder, preferredBundle: bundleID, scheme: selectedScheme),
                       let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
                       let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                       info["CFBundleIdentifier"] as? String == bundleID,
                       let profile = try? loadSigningProfile(app), profile.devices.contains(device) { return app.path }
                }
                return ""
            }.value
            if !Task.isCancelled { detectedArtifact = artifact }
        }
    }
}
