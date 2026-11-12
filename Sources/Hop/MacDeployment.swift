import Foundation
import Darwin

let localMacDeviceID = "hop-local-mac"

extension DeploymentConfig {
    var isMac: Bool { deviceID == localMacDeviceID }
}

func deploymentDestination(_ config: DeploymentConfig) -> String {
    config.isMac ? "platform=macOS" : "id=" + config.deviceID
}

// Read the selected scheme's actual app product, including custom product names and build directories.
func macBuildProduct(_ data: Data, scheme: String) throws -> URL {
    guard let targets = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw DeviceTrackingError.message("Couldn’t read the Mac app’s build settings.")
    }
    let apps = targets.filter { target in
        guard let settings = target["buildSettings"] as? [String: Any] else { return false }
        return settings["PLATFORM_NAME"] as? String == "macosx" &&
            settings["WRAPPER_EXTENSION"] as? String == "app" &&
            settings["PRODUCT_TYPE"] as? String == "com.apple.product-type.application"
    }
    let named = apps.filter { $0["target"] as? String == scheme }
    let candidates = named.isEmpty ? apps : named
    guard candidates.count == 1,
          let settings = candidates[0]["buildSettings"] as? [String: Any],
          let directory = settings["TARGET_BUILD_DIR"] as? String,
          let product = settings["FULL_PRODUCT_NAME"] as? String,
          !directory.isEmpty, product == URL(fileURLWithPath: product).lastPathComponent,
          product.hasSuffix(".app") else {
        throw DeviceTrackingError.message("Select a scheme that builds one macOS app.")
    }
    return URL(fileURLWithPath: directory).appendingPathComponent(product)
}

func macAppBundleID(_ app: URL) throws -> String {
    let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
          info["CFBundlePackageType"] as? String == "APPL",
          let executable = info["CFBundleExecutable"] as? String,
          !executable.isEmpty, executable == URL(fileURLWithPath: executable).lastPathComponent,
          FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/" + executable).path) else {
        throw DeviceTrackingError.message("The build did not produce a runnable Mac app.")
    }
    return bundleID
}

func macInstallationDirectory(for app: URL) -> URL {
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
    // Keep an existing installation in place rather than creating a second copy.
    if FileManager.default.fileExists(atPath: system.appendingPathComponent(app.lastPathComponent).path) ||
        FileManager.default.isWritableFile(atPath: system.path) { return system }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
}

// Stage the complete bundle first, then swap directories atomically. Running apps can be reopened later.
func installMacApp(_ app: URL, in directory: URL, name: String? = nil) throws -> URL {
    let fm = FileManager.default
    let bundleID = try macAppBundleID(app)
    let name = name ?? app.lastPathComponent
    guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".app") else {
        throw DeviceTrackingError.message("Choose an .app destination inside Applications.")
    }
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(name)
    func validateDestination() throws {
        if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw DeviceTrackingError.message("The installation destination is a symbolic link. Choose a regular Applications folder.")
        }
        if fm.fileExists(atPath: destination.path), (try? macAppBundleID(destination)) != bundleID {
            throw DeviceTrackingError.message("\(destination.lastPathComponent) belongs to another app. It hasn’t been replaced.")
        }
    }
    try validateDestination()
    let staging = directory.appendingPathComponent(".hop-install-" + UUID().uuidString + ".app")
    defer { try? fm.removeItem(at: staging) }
    try fm.copyItem(at: app, to: staging)
    try validateDestination()
    if fm.fileExists(atPath: destination.path) {
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw DeviceTrackingError.message("Couldn’t replace \(destination.lastPathComponent): " + String(cString: strerror(errno)))
        }
    } else {
        try fm.moveItem(at: staging, to: destination)
    }
    return destination
}
