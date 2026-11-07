import AppKit
import SwiftUI
import Foundation
import Darwin
import UniformTypeIdentifiers

struct Service: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var directory: String
    var command: String
    var url: String
}
enum Admission: String, Codable { case pending, added, settingsOnly }
struct Preferences: Codable {
    // Missing in saved settings from older versions: preserve their existing menu membership.
    var admission: Admission? = .pending
    var folderID: String?
    var title = ""
    var pinned = false
    var hidden = false
    var editor = "Visual Studio Code"
    var website = ""
    var note = ""
    var selected: Set<String> = []
    var services: [Service] = []
    var customizedServices = false
}
struct Project: Identifiable {
    var id: String { path }
    var path: String
    var title: String
    var modified: Date
    var branch: String
    var changes: Int
    var github: String
    var suggested: [Service]
    var xcode: String?
}
enum ProjectOrder: String, Codable, CaseIterable, Identifiable {
    case modified, alphabetical, manual
    var id: String { rawValue }
    var title: String { switch self { case .modified: return "Last modified"; case .alphabetical: return "Name"; case .manual: return "Manual" } }
}
struct ProjectFolder: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
}
enum CommandMode: String, Codable, CaseIterable { case background, terminal }
struct DiskState: Codable {
    var root = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Development"
    var projects: [String: Preferences] = [:]
    var order: ProjectOrder = .modified
    var manualOrder: [String] = []
    var folders: [ProjectFolder] = []
    var groupOrder: [String] = []
    var collapsedFolders: Set<String> = []
    var manualPaths: [String] = []
    var removedProjects: Set<String> = []
    var refreshSeconds = 60
    var refreshOnOpen = true
    var pinnedFirst = true
    var commandMode: CommandMode = .background
    var defaultEditor = "Visual Studio Code"
    var version = 2
    enum CodingKeys: String, CodingKey { case root, projects, order, manualOrder, folders, groupOrder, collapsedFolders, manualPaths, removedProjects, refreshSeconds, refreshOnOpen, pinnedFirst, commandMode, defaultEditor, version }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? root
        projects = try c.decodeIfPresent([String: Preferences].self, forKey: .projects) ?? [:]
        order = try c.decodeIfPresent(ProjectOrder.self, forKey: .order) ?? .modified
        manualOrder = try c.decodeIfPresent([String].self, forKey: .manualOrder) ?? []
        folders = try c.decodeIfPresent([ProjectFolder].self, forKey: .folders) ?? []
        groupOrder = try c.decodeIfPresent([String].self, forKey: .groupOrder) ?? []
        collapsedFolders = try c.decodeIfPresent(Set<String>.self, forKey: .collapsedFolders) ?? []
        manualPaths = try c.decodeIfPresent([String].self, forKey: .manualPaths) ?? []
        removedProjects = try c.decodeIfPresent(Set<String>.self, forKey: .removedProjects) ?? []
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 60
        refreshOnOpen = try c.decodeIfPresent(Bool.self, forKey: .refreshOnOpen) ?? true
        pinnedFirst = try c.decodeIfPresent(Bool.self, forKey: .pinnedFirst) ?? true
        commandMode = try c.decodeIfPresent(CommandMode.self, forKey: .commandMode) ?? .background
        defaultEditor = try c.decodeIfPresent(String.self, forKey: .defaultEditor) ?? "Visual Studio Code"
        let savedVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        if savedVersion < 2 {
            for id in Array(projects.keys) { projects[id]?.selected = [] }
        }
    }
}

let ignored: Set<String> = ["node_modules", "vendor", "Pods", "Carthage", "build", "dist", "DerivedData", "coverage", "venv", "env", "__pycache__", "target", "out"]
func children(_ url: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
}
func directory(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
func excluded(_ u: URL) -> Bool { ignored.contains(u.lastPathComponent) || ["xcodeproj", "xcworkspace", "app", "framework", "xcassets"].contains(u.pathExtension) }
func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func capture(_ executable: String, _ args: [String], at path: String? = nil) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
    if let path { p.currentDirectoryURL = URL(fileURLWithPath: path) }
    p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); timeout.cancel()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch { return "" }
}
func githubURL(_ remote: String) -> String {
    var r = remote
    if r.hasPrefix("git@github.com:") { r = "https://github.com/" + r.dropFirst(15) }
    if r.hasPrefix("ssh://git@github.com/") { r = r.replacingOccurrences(of: "ssh://git@github.com/", with: "https://github.com/") }
    if r.hasSuffix(".git") { r.removeLast(4) }
    guard let u = URL(string: r), u.host == "github.com", ["http", "https"].contains(u.scheme ?? "") else { return "" }
    return r
}
func suggestedService(_ folder: URL, label: String) -> Service? {
    let file = folder.appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: file), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let scripts = j["scripts"] as? [String: String], let script = scripts["dev"] != nil ? "dev" : (scripts["start"] != nil ? "start" : nil) else { return nil }
    let files = Set(children(folder).map(\.lastPathComponent))
    let manager = (j["packageManager"] as? String)?.components(separatedBy: "@").first ?? (files.contains("pnpm-lock.yaml") ? "pnpm" : files.contains("yarn.lock") ? "yarn" : files.contains("bun.lock") || files.contains("bun.lockb") ? "bun" : "npm")
    let safeManager = ["npm", "pnpm", "yarn", "bun"].contains(manager) ? manager : "npm"
    let command = "\(safeManager) run \(script)"
    let scriptText = scripts[script] ?? ""
    let port = scriptText.contains("vite") ? 5173 : scriptText.contains("wrangler") ? 8787 : 3000
    return Service(name: label, directory: folder.path, command: command, url: "http://localhost:\(port)")
}
func scan(_ root: String, manualPaths: [String] = []) -> [Project] {
    var roots: [URL] = [], budget = 12000
    func find(_ folder: URL, _ depth: Int, _ inside: Bool) {
        guard depth <= 6, budget > 0 else { return }; budget -= 1
        let entries = children(folder), names = Set(entries.map(\.lastPathComponent))
        let repo = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
        let marker = !names.isDisjoint(with: ["package.json", "Package.swift", "go.mod", "Cargo.toml", "pyproject.toml", "requirements.txt", "index.html"]) || entries.contains { $0.pathExtension == "xcodeproj" }
        let isProject = repo || (marker && !inside)
        if isProject { roots.append(folder) }
        for child in entries where directory(child) && !excluded(child) { find(child, depth + 1, inside || isProject) }
    }
    find(URL(fileURLWithPath: root), 0, false)
    var seen: Set<String> = []
    roots = (roots + manualPaths.map { URL(fileURLWithPath: $0) }.filter { directory($0) }).filter {
        seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted
    }
    return roots.map { folder in
        var modified = Date.distantPast, remaining = 25000
        func latest(_ dir: URL, _ depth: Int) {
            guard remaining > 0, depth < 16 else { return }
            for child in children(dir) where !excluded(child) {
                remaining -= 1; if remaining <= 0 { break }
                if directory(child) { latest(child, depth + 1) }
                else if let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { modified = max(modified, date) }
            }
        }
        latest(folder, 0)
        let branch = capture("/usr/bin/git", ["--no-optional-locks", "-C", folder.path, "branch", "--show-current"])
        let status = capture("/usr/bin/git", ["--no-optional-locks", "-C", folder.path, "status", "--porcelain", "--untracked-files=normal"])
        let remote = capture("/usr/bin/git", ["-C", folder.path, "remote", "get-url", "origin"])
        var services: [Service] = []
        if let s = suggestedService(folder, label: "Local server") { services.append(s) }
        for child in children(folder) where directory(child) && !excluded(child) {
            if let s = suggestedService(child, label: child.lastPathComponent.capitalized) { services.append(s) }
        }
        let xcodeCandidates = children(folder) + children(folder.appendingPathComponent("ios"))
        let xcode = xcodeCandidates.first { $0.pathExtension == "xcworkspace" }?.path ?? xcodeCandidates.first { $0.pathExtension == "xcodeproj" }?.path
        return Project(path: folder.path, title: folder.lastPathComponent, modified: modified, branch: branch.isEmpty ? (remote.isEmpty ? "" : "Detached HEAD") : branch, changes: status.isEmpty ? 0 : status.components(separatedBy: "\n").count, github: githubURL(remote), suggested: services, xcode: xcode)
    }.sorted { $0.modified > $1.modified }
}

@MainActor final class Store: ObservableObject {
    static let ungroupedFolderID = "__ungrouped__"
    @Published var disk = DiskState()
    @Published var projects: [Project] = []
    @Published var scanning = false
    @Published var message = "" {
        didSet {
            messageDismissal?.cancel()
            guard !message.isEmpty else { return }
            if !message.hasPrefix("Removed ") { lastRemovedPath = nil }
            let delay: UInt64 = message.hasPrefix("Removed ") ? 10 : (message == "Pushed successfully." ? 4 : 8)
            messageDismissal = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                catch { return }
                withAnimation(.easeInOut(duration: 0.2)) { self?.message = "" }
            }
        }
    }
    private var messageDismissal: Task<Void, Never>?
    @Published var phases: [String: String] = [:]
    @Published var external: Set<String> = []
    @Published var commitProject: Project?
    @Published var gitSync: [String: GitSyncState] = [:]
    @Published var syncing: Set<String> = []
    @Published var expanded: String?
    @Published var settingsProject: String?
    @Published var lastRefreshed: Date?
    @Published var reviewProject: Project?
    @Published var draggingProject: String?
    @Published var draggingFolder: String?
    @Published var dragScope: String?
    @Published var dragPoint: CGPoint = .zero
    @Published var dragHover: OrganizerDrop?
    var dragFrames: [String: [String: OrganizerFrame]] = [:]
    @Published var swipeProject: String?
    @Published var lastRemovedPath: String?
    var reviewRequested: ((Project) -> Void)?
    var promptedThisSession: Set<String> = []
    var showSettings: ((String?) -> Void)?
    var starting: Set<String> = []
    var processes: [String: Process] = [:]
    @Published var terminalRuns: [String: URL] = [:]
    var logURLs: [String: URL] = [:]
    var timer: Timer?
    let support: URL
    var stateURL: URL { support.appendingPathComponent("settings.json") }
    init(storage: URL? = nil, root: String? = nil, autoRefresh: Bool = true) {
        support = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hop")
        let legacyURLs = ["Switchyard/settings.json", "ProjectDock/settings.json"].map { support.deletingLastPathComponent().appendingPathComponent($0) }
        let oldStateURL = legacyURLs.first { FileManager.default.fileExists(atPath: $0.path) } ?? stateURL
        let loadURL = FileManager.default.fileExists(atPath: stateURL.path) ? stateURL : (storage == nil ? oldStateURL : stateURL)
        if let data = try? Data(contentsOf: loadURL), let state = try? JSONDecoder().decode(DiskState.self, from: data) { disk = state }
        if let root { disk.root = root }
        guard autoRefresh else { return }
        refresh()
        configureTimer()
    }
    func configureTimer() {
        timer?.invalidate(); timer = nil
        guard disk.refreshSeconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(15, disk.refreshSeconds)), repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func changeSettings(_ edit: (inout DiskState) -> Void) {
        let interval = disk.refreshSeconds
        edit(&disk); save()
        if interval != disk.refreshSeconds { configureTimer() }
    }
    func name(_ p: Project) -> String { prefs(p).title.isEmpty ? p.title : prefs(p).title }
    func orderedProjects(includeHidden: Bool = false) -> [Project] {
        let ranks = Dictionary(disk.manualOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return projects.filter { includeHidden || isInMenu($0) }.sorted { a, b in
            if disk.pinnedFirst && prefs(a).pinned != prefs(b).pinned { return prefs(a).pinned }
            switch disk.order {
            case .modified: if a.modified != b.modified { return a.modified > b.modified }
            case .alphabetical:
                let comparison = name(a).localizedStandardCompare(name(b))
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .manual:
                let x = ranks[a.id] ?? Int.max, y = ranks[b.id] ?? Int.max
                if x != y { return x < y }
                if a.modified != b.modified { return a.modified > b.modified }
            }
            return a.id < b.id
        }
    }
    func moveProject(_ source: String, before target: String) { placeProject(source, relativeTo: target, after: false) }
    @discardableResult func placeProject(_ source: String, relativeTo target: String, after: Bool) -> Bool {
        guard source != target, let a = projects.first(where: { $0.id == source }), let b = projects.first(where: { $0.id == target }) else { return false }
        var order = orderedProjects(includeHidden: true).map(\.id)
        order.removeAll { $0 == source }
        guard let index = order.firstIndex(of: target) else { return false }
        order.insert(source, at: index + (after ? 1 : 0))
        var pref = prefs(a); pref.folderID = folderID(b)
        if disk.pinnedFirst { pref.pinned = prefs(b).pinned }
        disk.projects[source] = pref
        disk.manualOrder = order; disk.order = .manual; save(); return true
    }
    var orderedGroupIDs: [String] {
        let current = disk.folders.map(\.id) + [Self.ungroupedFolderID]
        let valid = Set(current); var seen: Set<String> = []
        return (disk.groupOrder + current).filter { valid.contains($0) && seen.insert($0).inserted }
    }
    @discardableResult func moveFolder(_ source: String, relativeTo target: String, after: Bool) -> Bool {
        var order = orderedGroupIDs
        guard source != target, order.contains(source), order.contains(target) else { return false }
        order.removeAll { $0 == source }
        guard let index = order.firstIndex(of: target) else { return false }
        order.insert(source, at: index + (after ? 1 : 0)); disk.groupOrder = order
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        disk.folders.sort { (ranks[$0.id] ?? Int.max) < (ranks[$1.id] ?? Int.max) }
        save(); return true
    }
    func folderID(_ project: Project) -> String? {
        guard let id = prefs(project).folderID, disk.folders.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    @discardableResult func createFolder(_ title: String) -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let folder = ProjectFolder(title: clean); disk.folders.append(folder); save(); return folder.id
    }
    func renameFolder(_ id: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = disk.folders.firstIndex(where: { $0.id == id }) else { return }
        disk.folders[index].title = title; save()
    }
    func removeFolder(_ id: String) {
        disk.folders.removeAll { $0.id == id }; disk.groupOrder.removeAll { $0 == id }; disk.collapsedFolders.remove(id)
        for path in Array(disk.projects.keys) where disk.projects[path]?.folderID == id { disk.projects[path]?.folderID = nil }
        save()
    }
    @discardableResult func assignFolder(_ path: String, to folder: String?) -> Bool {
        guard let project = projects.first(where: { $0.id == path }), folder == nil || disk.folders.contains(where: { $0.id == folder }) else { return false }
        update(project) { $0.folderID = folder }; return true
    }
    func toggleFolder(_ id: String) { if disk.collapsedFolders.contains(id) { disk.collapsedFolders.remove(id) } else { disk.collapsedFolders.insert(id) }; save() }
    @discardableResult func addManualProject(_ url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard directory(canonical) else { message = "That project folder isn’t available."; return false }
        disk.removedProjects.remove(canonical.path)
        if !disk.manualPaths.contains(canonical.path) { disk.manualPaths.append(canonical.path); save() }
        refresh(); return true
    }
    func removeManualProject(_ path: String) { disk.manualPaths.removeAll { $0 == path }; save(); refresh() }
    func hideProject(_ project: Project) { update(project) { $0.hidden = true }; swipeProject = nil }
    @discardableResult func removeProject(_ project: Project) -> Bool {
        guard !services(project).contains(where: { isManaged(key(project, $0)) }) else {
            message = "Stop this project’s running services before removing it from Hop."; return false
        }
        disk.removedProjects.insert(project.id); projects.removeAll { $0.id == project.id }
        if settingsProject == project.id { settingsProject = nil }
        if reviewProject?.id == project.id { reviewProject = nil }
        if expanded == project.id { expanded = nil }
        swipeProject = nil; lastRemovedPath = project.id
        message = "Removed \(name(project)) from Hop."; save(); return true
    }
    func restoreProject(_ path: String) {
        disk.removedProjects.remove(path)
        if lastRemovedPath == path { lastRemovedPath = nil }
        message = ""; save(); refresh()
    }
    func isInMenu(_ project: Project) -> Bool {
        let pref = prefs(project)
        return (pref.admission == nil || pref.admission == .added) && !pref.hidden
    }
    var pendingProjects: [Project] { orderedProjects(includeHidden: true).filter { prefs($0).admission == .pending } }
    func offerNextReview() {
        guard reviewProject == nil, reviewRequested != nil,
              let project = pendingProjects.first(where: { !promptedThisSession.contains($0.id) }) else { return }
        beginReview(project)
    }
    func beginReview(_ project: Project) {
        guard reviewProject == nil else { return }
        promptedThisSession.insert(project.id)
        reviewProject = project; reviewRequested?(project)
    }
    func finishReview(_ project: Project, preferences: Preferences? = nil, add: Bool? = nil) {
        if var pref = preferences {
            pref.admission = .added; pref.hidden = false
            disk.projects[project.id] = pref; save()
        } else if let add {
            update(project) { $0.admission = add ? .added : .settingsOnly; $0.hidden = false }
        }
        reviewProject = nil
    }
    func prefs(_ p: Project) -> Preferences { disk.projects[p.id] ?? Preferences() }
    func services(_ p: Project) -> [Service] { prefs(p).services }
    func update(_ p: Project, _ edit: (inout Preferences) -> Void) {
        var pref = prefs(p); edit(&pref); disk.projects[p.id] = pref; save()
    }
    func save() {
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true); try JSONEncoder().encode(disk).write(to: stateURL, options: .atomic) }
        catch { message = "Couldn’t save settings: \(error.localizedDescription)" }
    }
    func refresh() {
        guard !scanning else { return }; scanning = true
        let root = disk.root
        let manualPaths = disk.manualPaths
        Task {
            let discovered = await Task.detached(priority: .utility) { scan(root, manualPaths: manualPaths) }.value
            guard disk.root == root && disk.manualPaths == manualPaths else { scanning = false; refresh(); return }
            let found = discovered.filter { !disk.removedProjects.contains($0.id) }
            for p in found where disk.projects[p.id] == nil {
                var pref = Preferences(); pref.services = p.suggested; pref.editor = disk.defaultEditor
                if p.xcode != nil { pref.editor = "Xcode" }
                disk.projects[p.id] = pref
            }
            projects = found; scanning = false; lastRefreshed = Date(); save()
            if !FileManager.default.fileExists(atPath: root) { message = "Project folder isn’t available. Choose a folder from Settings." }
            offerNextReview()
            for project in found { checkRemote(project) }
            await probeAll()
        }
    }
    func key(_ p: Project, _ s: Service) -> String { p.id + ":" + s.id }
    func validURL(_ text: String, local: Bool = false) -> URL? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }
        if !address.contains("://") {
            let hostPart = address.components(separatedBy: "/").first ?? ""
            let localAddress = hostPart == "localhost" || hostPart.hasPrefix("localhost:") || hostPart == "127.0.0.1" || hostPart.hasPrefix("127.0.0.1:") || hostPart.hasPrefix("[::1]")
            // Reject alternate URI schemes while still accepting host:port addresses.
            if address.contains(":") && !localAddress {
                guard let port = hostPart.split(separator: ":").last, Int(port) != nil else { return nil }
            }
            address = (local || localAddress ? "http://" : "https://") + address
        }
        guard let u = URL(string: address), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), let host = u.host, !host.isEmpty, !host.contains(" "), u.user == nil, u.password == nil else { return nil }
        if local && !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) { return nil }
        return u
    }
    func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5); request.httpMethod = "HEAD"
        do { let (_, response) = try await URLSession.shared.data(for: request); return response is HTTPURLResponse } catch { return false }
    }
    func ownsExternalEndpoint(_ service: Service) async -> Bool {
        guard let url = validURL(service.url, local: true), let port = url.port else { return false }
        let path = URL(fileURLWithPath: service.directory).resolvingSymlinksInPath().path
        return await Task.detached(priority: .utility) {
            let pids = capture("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]).components(separatedBy: "\n").filter { Int32($0) != nil }
            for pid in pids {
                let lines = capture("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]).components(separatedBy: "\n")
                if let cwd = lines.first(where: { $0.hasPrefix("n") }) {
                    let resolved = URL(fileURLWithPath: String(cwd.dropFirst())).resolvingSymlinksInPath().path
                    if resolved == path || resolved.hasPrefix(path + "/") { return true }
                }
            }
            return false
        }.value
    }
    func probeAll() async {
        for p in projects {
            for s in services(p) {
                let k = key(p,s)
                guard !isManaged(k), let url = validURL(s.url, local: true) else { continue }
                if await reachable(url), await ownsExternalEndpoint(s) { external.insert(k) } else { external.remove(k) }
            }
        }
    }
    func phase(_ p: Project, _ s: Service) -> String { phases[key(p,s)] ?? (external.contains(key(p,s)) ? "Running externally" : "Stopped") }
    func start(_ p: Project, _ s: Service) async {
        let k = key(p,s)
        guard !isManaged(k), !starting.contains(k) else { return }
        starting.insert(k)
        defer { starting.remove(k) }
        if let url = validURL(s.url, local: true), await reachable(url) {
            if await ownsExternalEndpoint(s) { external.insert(k); message = "\(s.name) is already running at \(s.url)." }
            else { phases[k] = "Address already in use"; message = "Another process is using \(s.url). Check this service’s port in project settings before starting." }
            return
        }
        guard !s.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "Set a launch command in this project’s settings first."; return }
        guard directory(URL(fileURLWithPath: s.directory)) else { message = "The service folder isn’t available: \(s.directory)"; return }
        if disk.commandMode == .terminal { await startInTerminal(p, s); return }
        let process = Process()
        guard let executable = Bundle.main.executableURL else { return }
        process.executableURL = executable; process.arguments = ["--run-service", s.command]
        process.currentDirectoryURL = URL(fileURLWithPath: s.directory)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = env
        do {
            let logs = support.appendingPathComponent("Logs"); try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent(s.id + ".log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle; process.standardError = handle
            process.terminationHandler = { [weak self] done in
                try? handle.close()
                Task { @MainActor in
                    guard let self, self.processes[k] === done else { return }
                    // Reap any subprocesses left in this launch's session.
                    Darwin.kill(-done.processIdentifier, SIGTERM)
                    self.processes.removeValue(forKey: k)
                    self.phases[k] = done.terminationStatus == 0 || done.terminationReason == .uncaughtSignal ? "Stopped" : "Exited (\(done.terminationStatus))"
                }
            }
            try process.run(); processes[k] = process; phases[k] = "Starting…"; logURLs[k] = log; external.remove(k)
            if let url = validURL(s.url, local: true) {
                for _ in 0..<40 {
                    guard processes[k] === process, process.isRunning else { return }
                    if await reachable(url) { phases[k] = "Running"; return }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if process.isRunning { phases[k] = "Process running · URL not ready" }
            } else { phases[k] = "Process running" }
        } catch { message = "Couldn’t start \(s.name): \(error.localizedDescription)" }
    }
    func stop(_ p: Project, _ s: Service) {
        let k = key(p,s)
        if let state = terminalRuns[k] { stopTerminal(k, state); return }
        guard let process = processes[k], process.isRunning else { return }
        phases[k] = "Stopping…"
        Darwin.kill(-process.processIdentifier, SIGTERM)
        process.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if processes[k] === process, process.isRunning { Darwin.kill(-process.processIdentifier, SIGKILL); Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
    func openWeb(_ text: String) { guard let url = validURL(text) else { message = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Add this project’s website in Settings first." : "That website address doesn’t look valid. Check it in project settings."; return }; NSWorkspace.shared.open(url) }
    func openEditor(_ p: Project) {
        let editor = prefs(p).editor
        let url = URL(fileURLWithPath: editor == "Xcode" ? (p.xcode ?? p.path) : p.path)
        let appNames = ["Visual Studio Code": "com.microsoft.VSCode", "Xcode": "com.apple.dt.Xcode", "Cursor": "com.todesktop.230313mzl4w4u92"]
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appNames[editor] ?? "com.microsoft.VSCode") else { message = "\(editor) isn’t installed."; return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.message = error.localizedDescription } }
        }
    }
    func openTerminal(_ p: Project) {
        Task {
            let error = await executeInTerminal("cd -- " + shellQuote(p.path) + " && clear")
            if !error.isEmpty { message = "Terminal: " + error }
        }
    }
    func isManaged(_ key: String) -> Bool { processes[key] != nil || terminalRuns[key] != nil }
    func startInTerminal(_ project: Project, _ service: Service) async {
        let k = key(project, service)
        let directory = support.appendingPathComponent("Runtime")
        let state = directory.appendingPathComponent(UUID().uuidString + ".json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: state)
            guard let executable = Bundle.main.executableURL else { return }
            terminalRuns[k] = state; phases[k] = "Starting in Terminal…"; logURLs.removeValue(forKey: k); external.remove(k)
            let command = "cd -- " + shellQuote(service.directory) + " && { clear; " + shellQuote(executable.path) + " --terminal-service " + shellQuote(service.command) + " " + shellQuote(state.path) + "; }"
            let error = await executeInTerminal(command)
            if !error.isEmpty {
                terminalRuns.removeValue(forKey: k); phases[k] = "Couldn’t open Terminal"; try? FileManager.default.removeItem(at: state); message = "Terminal: " + error; return
            }
            monitorTerminal(k, state)
            for _ in 0..<50 {
                guard terminalRuns[k] == state else { return }
                if let record = TerminalRecord.read(state), record.isAlive {
                    if let url = validURL(service.url, local: true) {
                        if await reachable(url) { phases[k] = "Running in Terminal"; return }
                    } else { phases[k] = "Running in Terminal"; return }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if let record = TerminalRecord.read(state), record.isAlive { phases[k] = "In Terminal · URL not ready" }
            else { stopTerminal(k, state); message = "The command didn’t start. Check its Terminal window." }
        } catch { message = "Couldn’t start Terminal service: \(error.localizedDescription)" }
    }
    func monitorTerminal(_ key: String, _ state: URL) {
        Task {
            while terminalRuns[key] == state {
                if let record = TerminalRecord.read(state), record.exitStatus != nil || !record.isAlive {
                    let code = record.exitStatus ?? 0
                    phases[key] = code == 0 || code >= 128 ? "Stopped" : "Exited (\(code))"
                    terminalRuns.removeValue(forKey: key); try? FileManager.default.removeItem(at: state); return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    func stopTerminal(_ key: String, _ state: URL) {
        phases[key] = "Stopping…"
        guard let record = TerminalRecord.read(state) else {
            terminalRuns.removeValue(forKey: key); try? FileManager.default.removeItem(at: state); phases[key] = "Stopped"; return
        }
        if record.isAlive { Darwin.kill(-record.pid, SIGTERM) }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if terminalRuns[key] == state, record.isAlive { Darwin.kill(-record.pid, SIGKILL) }
        }
    }
    func stopAllManaged() {
        for p in processes.values where p.isRunning { Darwin.kill(-p.processIdentifier, SIGTERM); p.terminate() }
        for state in terminalRuns.values {
            if let record = TerminalRecord.read(state), record.isAlive { Darwin.kill(-record.pid, SIGTERM) }
            else { try? FileManager.default.removeItem(at: state) }
        }
    }
    func availableActions(_ project: Project) -> Set<String> {
        let pref = prefs(project)
        var actions: Set<String> = ["terminal"]
        if !pref.editor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { actions.insert("editor") }
        if validURL(pref.website) != nil { actions.insert("website") }
        if validURL(project.github) != nil { actions.insert("github") }
        for service in services(project) {
            guard !service.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !service.directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            actions.insert("server:" + service.id)
            if validURL(service.url, local: true) != nil { actions.insert("web:" + service.id) }
        }
        return actions
    }
    func launch(_ p: Project) {
        let selected = prefs(p).selected.intersection(availableActions(p))
        if selected.contains("editor") { openEditor(p) }
        let launchingInTerminal = disk.commandMode == .terminal && services(p).contains { selected.contains("server:" + $0.id) }
        if selected.contains("terminal") && !launchingInTerminal { openTerminal(p) }
        if selected.contains("website") { openWeb(prefs(p).website) }
        if selected.contains("github") { openWeb(p.github) }
        Task {
            for s in services(p) {
                if selected.contains("server:" + s.id) { await start(p,s) }
                if selected.contains("web:" + s.id) {
                    if let url = validURL(s.url, local: true), await reachable(url) {
                        let belongs = isManaged(key(p,s)) ? true : await ownsExternalEndpoint(s)
                        if belongs { NSWorkspace.shared.open(url) }
                        else { message = "A different process is using \(s.url). Check this project’s local URL." }
                    }
                    else { message = "\(s.name) isn’t responding at its local URL. Check the address or open its logs." }
                }
            }
        }
    }
    func quit() {
        if !processes.isEmpty || !terminalRuns.isEmpty {
            let alert = NSAlert(); alert.messageText = "Stop running projects and quit?"; alert.informativeText = "Only servers started by Hop will be stopped."; alert.addButton(withTitle: "Stop & Quit"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        stopAllManaged()
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--run-service" {
    if setsid() < 0 && getpgrp() != getpid() {
        guard setpgid(0, 0) == 0 else { fputs("Could not isolate server process.\n", stderr); exit(1) }
    }
    let args = ["/bin/zsh", "-l", "-c", CommandLine.arguments[2]]
    let pointers = args.map { strdup($0) } + [nil]
    _ = pointers.withUnsafeBufferPointer { buffer in execv("/bin/zsh", buffer.baseAddress!) }
    exit(127)
} else if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--terminal-service" {
    runTerminalService(command: CommandLine.arguments[2], state: URL(fileURLWithPath: CommandLine.arguments[3]))
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--write-icon" {
    writeAppIcon(to: CommandLine.arguments[2])
} else if CommandLine.arguments.contains("--scan") {
    let root = CommandLine.arguments.last!
    for p in scan(root) { print("\(p.title) | \(p.branch) | \(p.changes) changes | \(p.github) | \(p.suggested.map(\.command).joined(separator: ", "))") }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        app.run()
    }
}
