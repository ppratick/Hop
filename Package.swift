// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Hop", platforms: [.macOS(.v14)], products: [.executable(name: "Hop", targets: ["Hop"])], targets: [.executableTarget(name: "Hop")])
