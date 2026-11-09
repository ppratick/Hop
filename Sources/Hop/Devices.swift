import AppKit
import SwiftUI

struct HopDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var model: String
    var platform: String
    var state: String
    var transport: String
    var statusLabel: String {
        switch state {
        case "connected", "disconnected": return "Available"
        case "unavailable": return "Unavailable"
        case "connecting": return "Connecting…"
        default: return "Status unknown"
        }
    }
    var symbol: String {
        platform == "tvOS" ? "appletv" : model.lowercased().contains("ipad") ? "ipad" : "iphone"
    }
}

struct SigningRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var projectID: String
    var deviceID: String
    var bundleID: String
    var installedAt: Date
    var expiresAt: Date
    var profileBased: Bool
    var artifactPath: String
    var installedByHop: Bool? = nil
    func remaining(at now: Date = Date()) -> String {
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return "Expired" }
        if seconds < 86400 { return "\(max(1, Int(ceil(seconds / 3600))))h remaining" }
        return "\(Int(ceil(seconds / 86400))) days remaining"
    }
    var tint: Color { expiresAt <= Date() ? .red : expiresAt.timeIntervalSinceNow < 172800 ? .orange : .blue }
}

struct SigningProfile {
    var expires: Date
    var bundleID: String
    var devices: [String]
}
enum DeviceTrackingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

func parseHopDevices(_ data: Data) throws -> [HopDevice] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = root["result"] as? [String: Any], let entries = result["devices"] as? [[String: Any]] else {
        throw DeviceTrackingError.message("Xcode returned an unrecognized device list.")
    }
    return entries.compactMap { entry in
        let props = entry["properties"] as? [String: Any] ?? [:]
        let hardware = props["hardware"] as? [String: Any] ?? entry["hardwareProperties"] as? [String: Any] ?? [:]
        let connection = props["connection"] as? [String: Any] ?? entry["connectionProperties"] as? [String: Any] ?? [:]
        let state = props["state"] as? [String: Any] ?? entry["deviceProperties"] as? [String: Any] ?? [:]
        guard connection["pairingState"] as? String == "paired",
              hardware["reality"] as? String != "simulated",
              let id = hardware["udid"] as? String ?? entry["identifier"] as? String else { return nil }
        return HopDevice(id: id, name: state["name"] as? String ?? "Apple device",
            model: hardware["marketingName"] as? String ?? hardware["productType"] as? String ?? "Apple device",
            platform: hardware["platform"] as? String ?? "iOS",
            state: connection["state"] as? String ?? connection["tunnelState"] as? String ?? "unknown",
            transport: connection["transportType"] as? String ?? "")
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

func discoverHopDevices() throws -> [HopDevice] {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hop-devices-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let output = temp.appendingPathComponent("devices.json")
    _ = capture("/usr/bin/xcrun", ["devicectl", "list", "devices", "--timeout", "6", "--json-output", output.path])
    guard let data = try? Data(contentsOf: output) else {
        throw DeviceTrackingError.message("Couldn’t discover devices. Check that Xcode is installed and devices are paired in Xcode → Window → Devices and Simulators.")
    }
    return try parseHopDevices(data)
}

func parseSigningProfile(_ data: Data) throws -> SigningProfile {
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let expiration = plist["ExpirationDate"] as? Date,
          let entitlements = plist["Entitlements"] as? [String: Any],
          let appID = (entitlements["application-identifier"] ?? entitlements["com.apple.application-identifier"]) as? String,
          let separator = appID.firstIndex(of: ".") else {
        throw DeviceTrackingError.message("This profile has no usable app identifier or expiration date.")
    }
    return SigningProfile(expires: expiration, bundleID: String(appID[appID.index(after: separator)...]),
                          devices: plist["ProvisionedDevices"] as? [String] ?? [])
}

func loadSigningProfile(_ url: URL) throws -> SigningProfile {
    let profile = url.pathExtension == "app" ? url.appendingPathComponent("embedded.mobileprovision") : url
    let decoded = capture("/usr/bin/security", ["cms", "-D", "-i", profile.path])
    guard let data = decoded.data(using: .utf8), !data.isEmpty else {
        throw DeviceTrackingError.message("Couldn’t read the embedded provisioning profile. Choose a signed device .app or .mobileprovision file.")
    }
    return try parseSigningProfile(data)
}

extension Store {
    func discoverDevices() {
        guard !discoveringDevices else { return }
        discoveringDevices = true
        deviceError = ""
        Task {
            do {
                let found = try await Task.detached(priority: .utility) { try discoverHopDevices() }.value
                discoveredDevices = found
                devicesCheckedAt = Date()
                for device in found where disk.devices.contains(where: { $0.id == device.id }) {
                    if let index = disk.devices.firstIndex(where: { $0.id == device.id }) { disk.devices[index] = device }
                }
                save()
            } catch { deviceError = error.localizedDescription }
            discoveringDevices = false
        }
    }
}

struct DevicesSettings: View {
    @ObservedObject var store: Store
    var listedDevices: [HopDevice] {
        (store.discoveredDevices + store.disk.devices.filter { saved in
            !store.discoveredDevices.contains { $0.id == saved.id }
        }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func isAvailable(_ device: HopDevice) -> Bool {
        store.discoveredDevices.contains { $0.id == device.id } &&
            (device.state == "connected" || device.state == "disconnected")
    }
    func deviceRow(_ device: HopDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol).font(.title3)
                .foregroundStyle(isAvailable(device) ? Color.blue : Color.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).fontWeight(.medium)
                Text(device.model).font(.caption).foregroundStyle(.secondary)
                if !store.discoveredDevices.contains(where: { $0.id == device.id }) {
                    Text("Not seen in last scan").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Toggle("Track", isOn: Binding(get: { store.disk.devices.contains { $0.id == device.id } }, set: { on in
                if on { store.disk.devices.append(device) }
                else { store.disk.devices.removeAll { $0.id == device.id } }
                store.save()
            })).toggleStyle(.switch).fixedSize()
        }.padding(.vertical, 3)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                GeneralSettingsCard(title: "Your devices", subtitle: "Your paired devices, grouped by availability.", icon: "iphone.and.ipad") {
                    HStack {
                        Text(store.devicesCheckedAt.map { "Checked " + $0.formatted(date: .omitted, time: .shortened) } ?? "Discover devices to check availability.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if store.discoveringDevices { ProgressView().controlSize(.small) }
                        Button("Refresh devices") { store.discoverDevices() }.disabled(store.discoveringDevices)
                    }
                    if !store.deviceError.isEmpty { Text(store.deviceError).foregroundStyle(.orange).font(.caption) }
                    ForEach([true, false], id: \.self) { available in
                        let group = listedDevices.filter { isAvailable($0) == available }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                Circle().fill(available ? Color.green : Color.secondary).frame(width: 6, height: 6)
                                Text(available ? "Available" : "Unavailable").fontWeight(.semibold)
                                Text("\(group.count)").foregroundStyle(.secondary).monospacedDigit()
                            }.font(.system(size: 11))
                            if group.isEmpty {
                                Text(available ? "No available devices." : "No unavailable devices.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(group) { device in deviceRow(device) }
                        }.padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if listedDevices.isEmpty {
                        Text("Pair your iPhone, iPad, or Apple TV in Xcode first. Network devices must already be paired.").foregroundStyle(.secondary)
                    }

                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
        .task { store.discoverDevices() }
    }
}

func xcodeAppBundleID(_ project: Project) -> String? {
    guard let xcode = project.xcode else { return nil }
    let url = URL(fileURLWithPath: xcode)
    let candidates = url.pathExtension == "xcodeproj" ? [url] :
        (children(URL(fileURLWithPath: project.path)) + children(URL(fileURLWithPath: project.path).appendingPathComponent("ios"))).filter { $0.pathExtension == "xcodeproj" }
    var identifiers = Set<String>()
    for candidate in candidates {
        let json = capture("/usr/bin/plutil", ["-convert", "json", "-o", "-", candidate.appendingPathComponent("project.pbxproj").path])
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]] else { continue }
        for target in objects.values where target["productType"] as? String == "com.apple.product-type.application" {
            guard let configID = target["buildConfigurationList"] as? String,
                  let configs = objects[configID]?["buildConfigurations"] as? [String] else { continue }
            for id in configs {
                let settings = objects[id]?["buildSettings"] as? [String: Any] ?? [:]
                if let bundle = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String, !bundle.contains("$"), !bundle.isEmpty {
                    identifiers.insert(bundle)
                }
            }
        }
    }
    return identifiers.count == 1 ? identifiers.first : nil
}

