import SwiftUI

func detectProjectPlatforms(at folder: URL, xcode: String?) -> [String] {
    let entries = children(folder)
    let names = Set(entries.map(\.lastPathComponent))
    var platforms: [String] = []
    var xcodeProjects = entries.filter { $0.pathExtension == "xcodeproj" }
    xcodeProjects += children(folder.appendingPathComponent("ios")).filter { $0.pathExtension == "xcodeproj" }
    if let xcode, xcode.hasSuffix(".xcodeproj"), !xcodeProjects.contains(where: { $0.path == xcode }) {
        xcodeProjects.append(URL(fileURLWithPath: xcode))
    }
    for project in xcodeProjects {
        guard let text = try? String(contentsOf: project.appendingPathComponent("project.pbxproj"), encoding: .utf8) else { continue }
        // Read SDK/platform declarations, rather than assuming every Xcode project is iOS.
        let pattern = #"(?:SDKROOT|SUPPORTED_PLATFORMS)\s*=\s*([^;]+);"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range(at: 1), in: text) else { continue }
                let value = text[r].lowercased()
                for (token, label) in [("iphone", "iOS"), ("macosx", "macOS"), ("appletv", "tvOS"), ("watch", "watchOS"), ("xros", "visionOS")] {
                    if value.contains(token) { platforms.append(label) }
                }
            }
        }
    }
    if platforms.isEmpty, let package = try? String(contentsOf: folder.appendingPathComponent("Package.swift"), encoding: .utf8) {
        for (token, label) in [(".macOS", "macOS"), (".iOS", "iOS"), (".tvOS", "tvOS"), (".watchOS", "watchOS"), (".visionOS", "visionOS")] {
            if package.contains(token) { platforms.append(label) }
        }
        if platforms.isEmpty { platforms.append("Swift") }
    }
    if names.contains("android") || names.contains("build.gradle") || names.contains("build.gradle.kts") { platforms.append("Android") }
    var dependencies = Set<String>()
    var hasCLI = names.contains("cli.py") || names.contains("cli.js") || names.contains("cli.ts")
    if let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        hasCLI = hasCLI || json["bin"] != nil
        dependencies.formUnion((json["dependencies"] as? [String: Any] ?? [:]).keys)
        dependencies.formUnion((json["devDependencies"] as? [String: Any] ?? [:]).keys)
    }
    if dependencies.contains("electron") { platforms.append("Desktop") }
    let webFrameworks: Set<String> = ["next", "vite", "react-dom", "vue", "nuxt", "svelte", "@sveltejs/kit", "astro", "@angular/core", "react-native-web"]
    if entries.contains(where: { $0.pathExtension == "html" }) || dependencies.contains("wrangler") || !dependencies.isDisjoint(with: webFrameworks) ||
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("public/index.html").path) {
        platforms.append("Web")
    }
    if let pyproject = try? String(contentsOf: folder.appendingPathComponent("pyproject.toml"), encoding: .utf8),
       pyproject.contains("[project.scripts]") || pyproject.contains("[tool.poetry.scripts]") { hasCLI = true }
    if hasCLI { platforms.append("CLI") }
    if platforms.isEmpty {
        if !dependencies.isDisjoint(with: ["express", "fastify", "koa", "@nestjs/core"]) { platforms.append("API") }
        else if names.contains("requirements.txt") || names.contains("pyproject.toml") { platforms.append("Python") }
        else if names.contains("Cargo.toml") { platforms.append("Rust") }
        else if names.contains("go.mod") { platforms.append("Go") }
        else if names.contains("package.json") { platforms.append("Node.js") }
        else if xcode != nil { platforms.append("Xcode") }
        else { platforms.append("Project") }
    }
    var seen = Set<String>()
    return platforms.filter { seen.insert($0).inserted }
}

struct ProjectPlatformBadges: View {
    let project: Project
    var compact = false
    var override: [String]? = nil
    var body: some View {
        HStack(spacing: 4) {
            ForEach(override ?? project.platforms, id: \.self) { platform in
                Text(platform)
                    .font(.system(size: compact ? 8 : 9, weight: .semibold))
                    .foregroundStyle(.blue.opacity(0.95))
                    .padding(.horizontal, compact ? 5 : 6).padding(.vertical, 3)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.blue.opacity(0.16)))
                    .fixedSize()
            }
        }.help(override == nil ? "Detected from this project’s platform and framework configuration" : "Platform badges set in project settings")
    }
}
