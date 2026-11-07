import AppKit
import SwiftUI
import UniformTypeIdentifiers

func hopMark(size: CGFloat = 18, color: NSColor = .black) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        color.setStroke()
        let transform = AffineTransform(scale: size / 20)
        let first = NSBezierPath()
        first.move(to: NSPoint(x: 3, y: 5)); first.line(to: NSPoint(x: 6, y: 5))
        first.curve(to: NSPoint(x: 13, y: 15), controlPoint1: NSPoint(x: 11, y: 5), controlPoint2: NSPoint(x: 8, y: 15))
        first.line(to: NSPoint(x: 17, y: 15)); first.move(to: NSPoint(x: 14, y: 12)); first.line(to: NSPoint(x: 17, y: 15)); first.line(to: NSPoint(x: 14, y: 18))
        let second = NSBezierPath()
        second.move(to: NSPoint(x: 3, y: 15)); second.line(to: NSPoint(x: 6, y: 15))
        second.curve(to: NSPoint(x: 13, y: 5), controlPoint1: NSPoint(x: 11, y: 15), controlPoint2: NSPoint(x: 8, y: 5))
        second.line(to: NSPoint(x: 17, y: 5)); second.move(to: NSPoint(x: 14, y: 2)); second.line(to: NSPoint(x: 17, y: 5)); second.line(to: NSPoint(x: 14, y: 8))
        for path in [first, second] { path.transform(using: transform); path.lineWidth = size / 10; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke() }
        return true
    }
    image.isTemplate = true
    return image
}
func writeAppIcon(to path: String) {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(calibratedRed: 0.02, green: 0.38, blue: 0.43, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.82, blue: 0.76, alpha: 1))?.draw(in: tile, angle: 55)
    let mark = hopMark(size: 500, color: .white); mark.isTemplate = false
    mark.draw(in: NSRect(x: 262, y: 262, width: 500, height: 500))
    NSGraphicsContext.restoreGraphicsState()
    if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
}

struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: hopMark(size: size)).renderingMode(.template).foregroundStyle(.white).padding(size * 0.22).background(LinearGradient(colors: [.teal, .cyan.opacity(0.75)], startPoint: .bottomLeading, endPoint: .topTrailing), in: RoundedRectangle(cornerRadius: size * 0.32))
    }
}
struct RootView: View {
    @ObservedObject var store: Store
    @State private var query = ""
    @FocusState private var focusedNote: String?
    var visible: [Project] {
        store.orderedProjects().filter { project in
            query.isEmpty || store.name(project).localizedCaseInsensitiveContains(query) || project.path.localizedCaseInsensitiveContains(query) || (store.disk.folders.first { $0.id == store.folderID(project) }?.title.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hop").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(query.isEmpty ? "\(visible.count) projects" : "\(visible.count) matching projects").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.scanning { ProgressView().controlSize(.small) }
                AddProjectMenu(store: store)
                Button { store.showSettings?(nil) } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Open Hop settings")
            }.padding(16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a project…", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 14).padding(.bottom, 12)
            if !store.message.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundStyle(.orange)
                    Text(store.message).font(.caption).textSelection(.enabled)
                    if let path = store.lastRemovedPath { Button("Undo") { store.restoreProject(path) }.buttonStyle(.borderless).font(.caption) }
                    Spacer()
                    Button { store.message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(.orange.opacity(0.08)).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            OrganizationList(store: store, scope: "menu") {
                LazyVStack(spacing: 8) {
                    if visible.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(.secondary)
                            Text(store.scanning ? "Finding your projects…" : "No projects found").font(.headline)
                            Button("Manage project folder") { store.showSettings?(nil) }
                        }.frame(maxWidth: .infinity).padding(30)
                    }
                    ForEach(store.orderedGroupIDs, id: \.self) { groupID in
                        let folder = store.disk.folders.first { $0.id == groupID }
                        let members = visible.filter { store.folderID($0) == folder?.id }
                        if (folder != nil && query.isEmpty) || !members.isEmpty || store.draggingProject != nil || store.draggingFolder != nil {
                            FolderHeader(store: store, folder: folder, count: members.count)
                            if !store.disk.collapsedFolders.contains(groupID) || !query.isEmpty {
                                projectRows(members).padding(.leading, 14)
                            }
                        }
                    }
                }.padding(12)
            }
        }.frame(width: 440, height: 680).background(.regularMaterial)
    }
    func projectRows(_ projects: [Project]) -> some View {
        VStack(spacing: 8) {
            ForEach(projects) { project in
                projectCard(project).modifier(ProjectDropTarget(store: store, project: project, allowsDragging: focusedNote != project.id))
            }
        }
    }
    func projectCard(_ p: Project) -> some View {
        let pref = store.prefs(p)
        let available = store.availableActions(p)
        let selected = pref.selected.intersection(available)
        let isOpen = store.expanded == p.id
        let running = store.services(p).contains { store.isManaged(store.key(p,$0)) || store.external.contains(store.key(p,$0)) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { store.expanded = isOpen ? nil : p.id } } label: {
                    HStack(spacing: 9) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.name(p)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            HStack(spacing: 5) {
                                if !p.branch.isEmpty {
                                    Image(systemName: "arrow.triangle.branch")
                                    Text(p.branch).lineLimit(1)
                                    Text("·")
                                    Text(p.changes == 0 ? "Clean" : "\(p.changes) changed").foregroundStyle(p.changes == 0 ? Color.secondary : Color.orange)
                                } else { Text("Local project") }
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if pref.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                        if running { Circle().fill(.green).frame(width: 6, height: 6) }
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                    Button(pref.pinned ? "Unpin" : "Pin to top") { store.update(p) { $0.pinned.toggle() } }
                    MoveToFolderMenu(store: store, project: p)
                    Button("Project settings…") { store.showSettings?(p.id) }
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.path) }
                    Divider()
                    Button("Hide project") { store.hideProject(p) }
                    Button("Remove from Hop", role: .destructive) { store.removeProject(p) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
            }.padding(12)
            if isOpen {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 10) {
                        if available.contains("editor") { action(p, "editor", "Editor", icon: "curlybraces", detail: pref.editor) }
                        action(p, "terminal", "Terminal", icon: "terminal", detail: "In project folder")
                        ForEach(store.services(p).filter { available.contains("server:" + $0.id) }) { s in
                            VStack(alignment: .leading, spacing: 7) {
                                action(p, "server:" + s.id, s.name, icon: "server.rack", detail: store.phase(p,s))
                                if store.isManaged(store.key(p,s)) {
                                    HStack(spacing: 12) {
                                        Spacer().frame(width: 18)
                                        Button("Stop") { store.stop(p,s) }
                                        Button("Restart") { Task {
                                            store.stop(p,s)
                                            for _ in 0..<30 { if !store.isManaged(store.key(p,s)) { break }; try? await Task.sleep(nanoseconds: 100_000_000) }
                                            await store.start(p,s)
                                        } }
                                        if let log = store.logURLs[store.key(p,s)] { Button("Logs") { NSWorkspace.shared.open(log) } }
                                        Spacer()
                                    }.font(.caption).buttonStyle(.borderless)
                                }
                                if available.contains("web:" + s.id) { action(p, "web:" + s.id, "Local website", icon: "globe", detail: s.url).padding(.leading, 24) }
                            }
                        }
                        if available.contains("website") { action(p, "website", "Deployed website", icon: "safari", detail: pref.website) }
                        if available.contains("github") { action(p, "github", "GitHub", icon: "chevron.left.forwardslash.chevron.right", detail: p.github.replacingOccurrences(of: "https://github.com/", with: "")) }
                    }
                    Button { store.launch(p) } label: { Text(selected.isEmpty ? "Select actions to launch" : "Launch selected").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 5) }.buttonStyle(.borderedProminent).tint(.teal).disabled(selected.isEmpty)
                    VStack(alignment: .leading, spacing: 5) {
                        Label("WHERE I LEFT OFF", systemImage: "text.alignleft").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        TextField("Leave a note for next time…", text: Binding(get: { store.prefs(p).note }, set: { value in store.update(p) { $0.note = value } }), axis: .vertical).focused($focusedNote, equals: p.id).lineLimit(2...5).textFieldStyle(.plain).font(.caption).padding(9).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Button("Project settings…") { store.showSettings?(p.id) }.font(.caption).buttonStyle(.borderless).frame(maxWidth: .infinity, alignment: .trailing)
                }.padding(12)
            }
        }.background(isOpen ? Color.primary.opacity(0.055) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
    func action(_ p: Project, _ id: String, _ title: String, icon: String, detail: String, enabled: Bool = true) -> some View {
        Toggle(isOn: Binding(get: { store.prefs(p).selected.contains(id) }, set: { checked in store.update(p) { if checked { $0.selected.insert(id) } else { $0.selected.remove(id) } } })) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 15).foregroundStyle(.secondary)
                Text(title).font(.caption)
                Spacer(minLength: 4)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .trailing).help(detail)
            }
        }.toggleStyle(.checkbox).disabled(!enabled)
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var filter = ""
    var selectedProject: Project? { store.projects.first { $0.id == store.settingsProject } }
    func setting<T>(_ path: WritableKeyPath<DiskState,T>) -> Binding<T> { Binding(get: { store.disk[keyPath: path] }, set: { value in store.changeSettings { $0[keyPath: path] = value } }) }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) { BrandMark(size: 28); VStack(alignment: .leading) { Text("Hop").font(.headline); Text("Settings").font(.caption).foregroundStyle(.secondary) } }.padding(20)
                Button { store.settingsProject = nil } label: {
                    Label("General", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading).padding(10).background(store.settingsProject == nil ? Color.teal.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.horizontal, 10)
                HStack { Text("PROJECTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Spacer(); AddProjectMenu(store: store) }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 10)
                TextField("Search projects", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 8)
                OrganizationList(store: store, scope: "settings") {
                    LazyVStack(spacing: 3) {
                        ForEach(store.orderedGroupIDs, id: \.self) { groupID in
                            let folder = store.disk.folders.first { $0.id == groupID }
                            let members = sidebarProjects.filter { store.folderID($0) == folder?.id }
                            if filter.isEmpty || !members.isEmpty {
                                FolderHeader(store: store, folder: folder, count: members.count, compact: true)
                                if !store.disk.collapsedFolders.contains(groupID) || !filter.isEmpty { sidebarRows(members).padding(.leading, 14) }
                            }
                        }
                    }.padding(.horizontal, 10)
                }
                Text("Changes save automatically").font(.system(size: 10)).foregroundStyle(.tertiary).padding(16)
            }.frame(width: 260).background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedProject.map { store.name($0) } ?? "General").font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(selectedProject == nil ? "Make Hop work your way." : "Editor, websites, and local services.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.scanning { ProgressView().controlSize(.small) }
                }.padding(26)
                if !store.message.isEmpty {
                    HStack { Text(store.message).font(.caption).foregroundStyle(.orange); if let path = store.lastRemovedPath { Button("Undo") { store.restoreProject(path) } }; Spacer(); Button { store.message = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(.horizontal, 26).padding(.bottom, 8)
                }
                if let project = selectedProject { ProjectSettings(store: store, project: project) }
                else { general }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 850, idealWidth: 920, minHeight: 610, idealHeight: 720)
            .sheet(item: $store.reviewProject, onDismiss: { store.offerNextReview() }) { project in
                NewProjectReview(store: store, project: project)
            }
    }
    var sidebarProjects: [Project] {
        store.orderedProjects(includeHidden: true).filter { project in
            filter.isEmpty || store.name(project).localizedCaseInsensitiveContains(filter) || (store.disk.folders.first { $0.id == store.folderID(project) }?.title.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }
    func sidebarRows(_ projects: [Project]) -> some View {
        VStack(spacing: 7) {
            ForEach(projects) { p in
                HStack(spacing: 6) {
                    Button { store.settingsProject = p.id } label: {
                        HStack {
                            Text(store.name(p)).lineLimit(2); Spacer(minLength: 0)
                            if store.prefs(p).admission == .pending { Text("NEW").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange) }
                            else if !store.isInMenu(p) { Image(systemName: "eye.slash").font(.caption2) }
                            else if store.prefs(p).pinned { Image(systemName: "pin.fill").font(.caption2) }
                        }.font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 12).padding(.vertical, 10).background(store.settingsProject == p.id ? Color.teal.opacity(0.16) : Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 9))
                    .modifier(ProjectDropTarget(store: store, project: p, scope: "settings"))
                    .contextMenu {
                        MoveToFolderMenu(store: store, project: p)
                        Button(store.prefs(p).hidden ? "Show in menu bar" : "Hide from menu bar") {
                            if store.prefs(p).hidden { store.beginReview(p) } else { store.hideProject(p) }
                        }
                        Button("Remove from Hop", role: .destructive) { store.removeProject(p) }
                    }
            }
        }
    }
    var general: some View {
        Form {
            if !store.pendingProjects.isEmpty {
                Section("New projects to review") {
                    ForEach(store.pendingProjects) { project in
                        HStack { Text(store.name(project)); Spacer(); Button("Review…") { store.beginReview(project) } }
                    }
                    Text("New projects stay in Settings until you choose to add them to the menu bar.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Projects") {
                LabeledContent("Auto-discovery source folder") {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(store.disk.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).lineLimit(3).textSelection(.enabled)
                        Button("Choose folder…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { store.changeSettings { $0.root = url.path }; store.refresh() }
                        }
                    }
                }
                Picker("Automatic refresh", selection: setting(\.refreshSeconds)) {
                    Text("Off").tag(0); Text("Every 15 seconds").tag(15); Text("Every 30 seconds").tag(30); Text("Every minute").tag(60); Text("Every 5 minutes").tag(300)
                }
                Toggle("Refresh when opening the menu", isOn: setting(\.refreshOnOpen))
                HStack { if let date = store.lastRefreshed { Text("Updated \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }; Spacer(); Button("Refresh now") { store.refresh() }.disabled(store.scanning) }
                ForEach(store.disk.manualPaths, id: \.self) { path in
                    HStack {
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("Stop tracking") { store.removeManualProject(path) }.help("Remove this added location from Hop. Project files stay untouched.")
                    }
                }
                Button("Add project from anywhere…", systemImage: "folder.badge.plus") { store.chooseProjects() }
                if !store.disk.removedProjects.isEmpty {
                    DisclosureGroup("Removed projects") {
                        ForEach(store.disk.removedProjects.sorted(), id: \.self) { path in
                            HStack {
                                Text(store.disk.projects[path]?.title.isEmpty == false ? store.disk.projects[path]!.title : URL(fileURLWithPath: path).lastPathComponent)
                                Spacer(); Button("Restore") { store.restoreProject(path) }
                            }
                        }
                    }
                }
            }
            Section("Folders") {
                ForEach(store.disk.folders) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.teal)
                        TextField("Folder name", text: Binding(get: { store.disk.folders.first { $0.id == folder.id }?.title ?? "" }, set: { store.renameFolder(folder.id, to: $0) }))
                        Button("Remove") { store.removeFolder(folder.id) }
                    }
                }
                Button("New folder…", systemImage: "plus") { store.askForFolder() }
                Text("Folders organize Hop. Your project files stay in their original locations.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Project order") {
                Picker("Sort by", selection: setting(\.order)) { ForEach(ProjectOrder.allCases) { Text($0.title).tag($0) } }
                Toggle("Keep pinned projects at the top", isOn: setting(\.pinnedFirst))
                Text("Press and drag a project card to lift it. Drop at an insertion line to reorder, or onto a folder to organize it. Reordering switches to manual order.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Launch preferences") {
                Picker("Run service commands in", selection: setting(\.commandMode)) {
                    Text("Background").tag(CommandMode.background)
                    Text("Terminal").tag(CommandMode.terminal)
                }
                Text("Background keeps output in logs. Terminal runs each service in its own shell, showing the command and live output. Applies the next time a service starts.").font(.caption).foregroundStyle(.secondary)
                Picker("Default editor for new projects", selection: setting(\.defaultEditor)) { editorOptions }
                Text("Actions start unchecked for new projects. Your selections are remembered separately for each project.").font(.caption).foregroundStyle(.secondary)
            }
            Section("App data") {
                HStack { Text("Settings and logs are kept outside your projects.").foregroundStyle(.secondary); Spacer(); Button("Show in Finder") { NSWorkspace.shared.open(store.support) } }
            }
        }.formStyle(.grouped)
    }
}
@ViewBuilder var editorOptions: some View { Text("Visual Studio Code").tag("Visual Studio Code"); Text("Xcode").tag("Xcode"); Text("Cursor").tag("Cursor") }
struct ProjectSettings: View {
    @ObservedObject var store: Store
    let project: Project
    func field<T>(_ keyPath: WritableKeyPath<Preferences,T>) -> Binding<T> { Binding(get: { store.prefs(project)[keyPath: keyPath] }, set: { value in store.update(project) { $0[keyPath: keyPath] = value } }) }
    func serviceField(_ id: String, _ keyPath: WritableKeyPath<Service,String>) -> Binding<String> {
        Binding(get: { store.services(project).first { $0.id == id }?[keyPath: keyPath] ?? "" }, set: { value in store.update(project) { pref in if let i = pref.services.firstIndex(where: { $0.id == id }) { pref.services[i][keyPath: keyPath] = value } } })
    }
    func serviceInput(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt)).labelsHidden().textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        }
    }
    var body: some View {
        Form {
            Section("Project") {
                TextField("Display name", text: field(\.title), prompt: Text(project.title))
                LabeledContent("Folder") { Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).textSelection(.enabled).lineLimit(3) }
                Picker("Folder", selection: Binding(get: { store.folderID(project) ?? "" }, set: { store.assignFolder(project.id, to: $0.isEmpty ? nil : $0) })) {
                    Text("Ungrouped").tag("")
                    ForEach(store.disk.folders) { folder in Text(folder.title).tag(folder.id) }
                }
                Toggle("Pinned", isOn: field(\.pinned))
                Toggle("Show in menu bar", isOn: Binding(get: { store.isInMenu(project) }, set: { show in
                    if show { store.beginReview(project) }
                    else { store.update(project) { $0.admission = .settingsOnly; $0.hidden = false } }
                }))
                Picker("Editor", selection: field(\.editor)) { editorOptions }
                TextField("Deployed website", text: field(\.website), prompt: Text("https://example.com"))
            }
            Section("Local services") {
                if store.services(project).isEmpty { Text("Add a service to run this project locally.").foregroundStyle(.secondary) }
                ForEach(store.services(project)) { s in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(s.name).font(.headline); Spacer(); Text(store.phase(project,s)).font(.caption).foregroundStyle(.secondary) }
                        Group {
                            serviceInput("Name", text: serviceField(s.id, \.name))
                            serviceInput("Working folder", text: serviceField(s.id, \.directory))
                            serviceInput("Launch command", text: serviceField(s.id, \.command), prompt: "npm run dev")
                            serviceInput("Local website", text: serviceField(s.id, \.url), prompt: "http://localhost:3000")
                        }.disabled(store.isManaged(store.key(project,s)))
                        HStack(spacing: 12) {
                            let owned = store.isManaged(store.key(project,s))
                            Button(owned ? "Stop" : "Start") { if owned { store.stop(project,s) } else { Task { await store.start(project,s) } } }.disabled(!owned && store.external.contains(store.key(project,s)))
                            if let log = store.logURLs[store.key(project,s)] { Button("Open logs") { NSWorkspace.shared.open(log) } }
                            Spacer()
                            Button("Remove", role: .destructive) { store.update(project) { $0.services.removeAll { $0.id == s.id }; $0.selected.remove("server:" + s.id); $0.selected.remove("web:" + s.id) } }.disabled(owned)
                        }
                    }.padding(.vertical, 6)
                }
                Button("Add service", systemImage: "plus") { store.update(project) { $0.services.append(Service(name: "Local server", directory: project.path, command: "", url: "http://localhost:3000")) } }
                Text("Check detected commands and ports before starting. You can configure frontend and backend services separately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Where I left off") {
                TextField("Note", text: field(\.note), axis: .vertical).lineLimit(3...6)
            }
        }.formStyle(.grouped)
    }
}

struct NewProjectReview: View {
    @ObservedObject var store: Store
    let project: Project
    @State private var configuring = false
    @State private var draft: Preferences
    @State private var configureServer: Bool
    init(store: Store, project: Project) {
        self.store = store; self.project = project
        _draft = State(initialValue: store.prefs(project))
        _configureServer = State(initialValue: !store.prefs(project).services.isEmpty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                BrandMark(size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(configuring ? "Set up \(project.title)" : "Add \(project.title) to your menu?").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(configuring ? "Choose how this project opens. Nothing will run during setup." : "Hop found a project in your source folder.").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
            if configuring {
                Form {
                    Section("How do you want to open it?") {
                        TextField("Display name", text: $draft.title, prompt: Text(project.title))
                        Picker("Editor", selection: $draft.editor) { editorOptions }
                        TextField("Deployed website (optional)", text: $draft.website, prompt: Text("example.com"))
                        Picker("Folder", selection: Binding(get: { draft.folderID ?? "" }, set: { draft.folderID = $0.isEmpty ? nil : $0 })) {
                            Text("Ungrouped").tag("")
                            ForEach(store.disk.folders) { folder in Text(folder.title).tag(folder.id) }
                        }
                        Toggle("Pin to the top", isOn: $draft.pinned)
                    }
                    Section("Does this project have a local server?") {
                        Toggle("Configure local services", isOn: $configureServer)
                            .onChange(of: configureServer) { _, enabled in
                                if enabled && draft.services.isEmpty { draft.services.append(Service(name: "Local server", directory: project.path, command: "", url: "localhost:3000")) }
                            }
                        if configureServer {
                            ForEach($draft.services) { $service in
                                VStack(alignment: .leading, spacing: 9) {
                                    TextField("Service name", text: $service.name).textFieldStyle(.roundedBorder)
                                    VStack(alignment: .leading, spacing: 4) { Text("Working folder").font(.caption).foregroundStyle(.secondary); TextField("Working folder", text: $service.directory).textFieldStyle(.roundedBorder) }
                                    VStack(alignment: .leading, spacing: 4) { Text("Launch command").font(.caption).foregroundStyle(.secondary); TextField("npm run dev", text: $service.command).textFieldStyle(.roundedBorder) }
                                    VStack(alignment: .leading, spacing: 4) { Text("Local address").font(.caption).foregroundStyle(.secondary); TextField("localhost:3000", text: $service.url).textFieldStyle(.roundedBorder) }
                                    Button("Remove service", role: .destructive) { draft.services.removeAll { $0.id == service.id } }.font(.caption)
                                }.padding(.vertical, 5)
                            }
                            Button("Add another service", systemImage: "plus") { draft.services.append(Service(name: "Backend", directory: project.path, command: "", url: "localhost:3001")) }
                        }
                    }
                    Text("Launch actions start unchecked. Choose them in the menu, and Hop will remember your selections.").font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("You can add it now and choose its editor, website, and local server settings—or keep it available only in Settings.").font(.body)
                }.padding(.horizontal, 24).padding(.bottom, 28)
            }
            Divider()
            HStack(spacing: 12) {
                if configuring { Button("Back") { configuring = false } }
                else { Button("Keep in Settings") { store.finishReview(project, add: false) } }
                Spacer()
                Button("Not now") { store.finishReview(project) }.keyboardShortcut(.cancelAction)
                Button(configuring ? "Add to menu bar" : "Configure & Add") {
                    if configuring {
                        if !configureServer { draft.services = [] }
                        store.finishReview(project, preferences: draft)
                    } else { configuring = true }
                }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 610, height: configuring ? 640 : 280)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    var status: NSStatusItem!
    var popover = NSPopover()
    var store: Store!
    var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--test-profile"), CommandLine.arguments.count > index + 1 {
            store = Store(storage: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else { store = Store() }
        installMainMenu()
        store.showSettings = { [weak self] project in self?.openSettings(project) }
        store.reviewRequested = { [weak self] project in self?.openSettings(project.id) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = hopMark()
        status.button?.toolTip = "Hop"
        status.button?.target = self; status.button?.action = #selector(toggle)
        popover.contentSize = NSSize(width: 440, height: 680); popover.behavior = .transient; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: RootView(store: store))
        if CommandLine.arguments.contains("--settings") { openSettings(nil) }
        else if CommandLine.arguments.contains("--show") { toggle() }
    }
    func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsAction), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Hop", action: #selector(quitAction), keyEquivalent: "q"); quit.target = self; appMenu.addItem(quit)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        NSApp.mainMenu = menu
    }
    @objc func settingsAction() { openSettings(nil) }
    @objc func quitAction() { store.quit() }
    func openSettings(_ project: String?) {
        popover.performClose(nil); store.settingsProject = project
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Hop Settings"; window.minSize = NSSize(width: 850, height: 650)
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { if (notification.object as? NSWindow) === settingsWindow { NSApp.setActivationPolicy(.accessory) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(nil); return true }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = status.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if store.disk.refreshOnOpen { store.refresh() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.stopAllManaged()
        return .terminateNow
    }
}
