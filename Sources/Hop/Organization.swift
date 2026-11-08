import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor extension Store {
    func chooseProjects() {
        showSettings?(nil)
        let panel = NSOpenPanel()
        panel.title = "Add projects to Hop"; panel.prompt = "Add projects"
        panel.message = "Choose project folders anywhere on your Mac. Files stay where they are."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { _ = addManualProject(url) } }
    }
    func askForFolder(_ existing: ProjectFolder? = nil, moving project: String? = nil) {
        let alert = NSAlert(); alert.messageText = existing == nil ? "New folder" : "Rename folder"
        alert.informativeText = "Organize projects in Hop. Your files won’t move."
        let field = NSTextField(string: existing?.title ?? ""); field.placeholderString = "Folder name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: existing == nil ? "Create folder" : "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let existing { renameFolder(existing.id, to: field.stringValue) }
        else if let id = createFolder(field.stringValue), let project { assignFolder(project, to: id) }
    }
    @discardableResult func dropIntoFolder(_ path: String, folder: String?) -> Bool {
        guard assignFolder(path, to: folder) else { return false }
        var order = orderedProjects(includeHidden: true).map(\.id).filter { $0 != path }
        let members = Set(projects.filter { $0.id != path && folderID($0) == folder }.map(\.id))
        let index = order.lastIndex(where: { members.contains($0) }).map { $0 + 1 } ?? order.count
        order.insert(path, at: index); disk.manualOrder = order; disk.order = .manual; disk.collapsedFolders.remove(folder ?? Store.ungroupedFolderID); save(); return true
    }
}
struct ProjectDropTarget: ViewModifier {
    @ObservedObject var store: Store
    let project: Project
    var scope = "menu"
    var allowsDragging = true
    var lifted: Bool { store.draggingProject == project.id && store.dragScope == scope }
    func body(content: Content) -> some View {
        content
            .modifier(OrganizerGeometry(item: .project(project.id), scope: scope))
            .scaleEffect(lifted ? 1.025 : 1)
            .shadow(color: .black.opacity(lifted ? 0.3 : 0), radius: 14, y: 6)
            .offset(store.projectDragOffset(project, scope: scope))
            .zIndex(lifted ? 10 : 0)
            .animation(lifted ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: store.dragHover)
            .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(scope))
                .onChanged { value in store.updateOrganizerDrag(.project(project.id), scope: scope, point: value.location) }
                .onEnded { value in store.updateOrganizerDrag(.project(project.id), scope: scope, point: value.location); store.finishOrganizerDrag() }, including: allowsDragging ? .all : .none)
    }
}

struct FolderHeader: View {
    @ObservedObject var store: Store
    let folder: ProjectFolder?
    let count: Int
    var compact = false
    var targeted: Bool {
        if store.dragHover == .insideFolder(groupID) { return true }
        if case let .folder(id, _) = store.dragHover { return id == groupID }
        return false
    }
    var scope: String { compact ? "settings" : "menu" }
    var groupID: String { folder?.id ?? Store.ungroupedFolderID }
    var collapsed: Bool { store.disk.collapsedFolders.contains(groupID) }
    var body: some View {
        Button { withAnimation { store.toggleFolder(groupID) } } label: {
            HStack(spacing: 9) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 10)
                Image(systemName: folder == nil ? "square.grid.2x2" : targeted ? "folder.badge.plus" : "folder.fill").foregroundStyle(targeted ? Color.blue : (compact ? Color.blue.opacity(0.8) : Color.secondary))
                Text(folder?.title ?? "Ungrouped").lineLimit(2)
                Spacer(minLength: 0)
                if targeted { Image(systemName: "arrow.down.to.line").foregroundStyle(.primary) }
                else {
                    Text("\(count)").font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.055), in: Capsule())
                }
            }.font(.system(size: compact ? 12 : 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: compact ? 22 : 34, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, compact ? 7 : 12)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .opacity(store.draggingFolder == groupID ? 0.4 : 1)
            .background(targeted ? Color.blue.opacity(0.22) : Color.blue.opacity(compact ? 0.07 : 0.085), in: RoundedRectangle(cornerRadius: compact ? 9 : 10))
            .overlay { if targeted { RoundedRectangle(cornerRadius: 9).strokeBorder(.blue.opacity(0.5), lineWidth: 1).allowsHitTesting(false) } }
            .contextMenu {
                Button(collapsed ? "Expand" : "Collapse") { store.toggleFolder(groupID) }
                if let folder {
                    Button("Rename…") { store.askForFolder(folder) }
                    Button("Remove folder") { store.removeFolder(folder.id) }
                }
            }

            .modifier(OrganizerGeometry(item: .folder(groupID), scope: scope))
            .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(scope))
                .onChanged { value in store.updateOrganizerDrag(.folder(groupID), scope: scope, point: value.location) }
                .onEnded { value in store.updateOrganizerDrag(.folder(groupID), scope: scope, point: value.location); store.finishOrganizerDrag() })
    }

}

struct MoveToFolderMenu: View {
    @ObservedObject var store: Store
    let project: Project
    var body: some View {
        Menu("Move to folder") {
            Button("Ungrouped") { store.assignFolder(project.id, to: nil) }
            ForEach(store.disk.folders) { folder in Button(folder.title) { store.assignFolder(project.id, to: folder.id) } }
            Divider()
            Button("New folder…") { store.askForFolder(moving: project.id) }
        }
    }
}
struct AddProjectMenu: View {
    @ObservedObject var store: Store
    var body: some View {
        Menu {
            Button("Add project…", systemImage: "folder.badge.plus") { store.chooseProjects() }
            Button("New folder…", systemImage: "folder") { store.askForFolder() }
        } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).help("Add a project or organize a folder")
    }
}

// The same SwiftUI coordinate space drives both the source gesture and drop
// targeting. This avoids competing AppKit/SwiftUI recognizers on card buttons.
enum OrganizerItem: Hashable { case project(String), folder(String)
    var key: String { switch self { case .project(let id): return "project:" + id; case .folder(let id): return "folder:" + id } }
}
enum OrganizerDrop: Equatable { case project(String, after: Bool), folder(String, after: Bool), insideFolder(String) }
struct OrganizerFrame: Equatable { var item: OrganizerItem; var rect: CGRect }
struct OrganizerFramesKey: PreferenceKey {
    static var defaultValue: [String: OrganizerFrame] = [:]
    static func reduce(value: inout [String: OrganizerFrame], nextValue: () -> [String: OrganizerFrame]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}
struct OrganizerGeometry: ViewModifier {
    let item: OrganizerItem
    let scope: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { geometry in
            Color.clear.preference(key: OrganizerFramesKey.self, value: [item.key: OrganizerFrame(item: item, rect: geometry.frame(in: .named(scope)))])
        })
    }
}
struct OrganizationList<Content: View>: View {
    @ObservedObject var store: Store
    let scope: String
    let content: Content
    init(store: Store, scope: String, @ViewBuilder content: () -> Content) { self.store = store; self.scope = scope; self.content = content() }
    var body: some View {
        ScrollView { content }.coordinateSpace(name: scope)
            .onPreferenceChange(OrganizerFramesKey.self) { frames in store.dragFrames[scope] = frames }
            .overlay {
                GeometryReader { geometry in
                    if store.dragScope == scope, store.draggingFolder != nil, let title = store.dragTitle {
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            .frame(width: 200, height: 44).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary, lineWidth: 1.5) }
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            .position(x: min(max(105, store.dragPoint.x + 65), geometry.size.width - 105), y: max(24, store.dragPoint.y - 18))
                    }
                }.allowsHitTesting(false)
            }
    }
}
@MainActor extension Store {
    var organizerItem: OrganizerItem? {
        if let id = draggingProject { return .project(id) }
        if let id = draggingFolder { return .folder(id) }
        return nil
    }
    var dragTitle: String? {
        if let id = draggingProject, let project = projects.first(where: { $0.id == id }) { return name(project) }
        if let id = draggingFolder { return disk.folders.first(where: { $0.id == id })?.title ?? "Ungrouped" }
        return nil
    }
    func projectDragOffset(_ project: Project, scope: String) -> CGSize {
        guard dragScope == scope, let sourceID = draggingProject,
              let source = projects.first(where: { $0.id == sourceID }),
              !dragInitialFrames.isEmpty,
              let sourceFrame = dragInitialFrames[OrganizerItem.project(sourceID).key]?.rect else { return .zero }
        if project.id == sourceID {
            return CGSize(width: max(-12, min(12, dragPoint.x - dragStartPoint.x)),
                          height: dragPoint.y - dragStartPoint.y)
        }
        guard case let .project(targetID, after) = dragHover,
              let target = projects.first(where: { $0.id == targetID }),
              folderID(source) == folderID(target),
              folderID(project) == folderID(source),
              let targetFrame = dragInitialFrames[OrganizerItem.project(targetID).key]?.rect,
              let row = dragInitialFrames[OrganizerItem.project(project.id).key]?.rect else { return .zero }
        let distance = sourceFrame.height + (scope == "settings" ? 5 : 8)
        if targetFrame.midY > sourceFrame.midY,
           row.midY > sourceFrame.midY,
           (row.midY < targetFrame.midY || (project.id == targetID && after)) {
            return CGSize(width: 0, height: -distance)
        }
        if targetFrame.midY < sourceFrame.midY,
           row.midY < sourceFrame.midY,
           (row.midY > targetFrame.midY || (project.id == targetID && !after)) {
            return CGSize(width: 0, height: distance)
        }
        return .zero
    }
    func updateOrganizerDrag(_ item: OrganizerItem, scope: String, point: CGPoint) {
        if organizerItem != item || dragScope != scope {
            dragStartPoint = point
            dragInitialFrames = dragFrames[scope] ?? [:]
        }

        switch item {
        case .project(let id): draggingProject = id; draggingFolder = nil
        case .folder(let id): draggingFolder = id; draggingProject = nil
        }
        dragScope = scope; dragPoint = point
        let target = dragInitialFrames.values.filter { $0.item != item && $0.rect.contains(point) }.min { $0.rect.height < $1.rect.height }
        guard let target else { dragHover = nil; return }
        switch (item, target.item) {
        case (.project, .project(let id)): dragHover = .project(id, after: point.y >= target.rect.midY)
        case (.project, .folder(let id)): dragHover = .insideFolder(id)
        case (.folder, .folder(let id)): dragHover = .folder(id, after: point.y >= target.rect.midY)
        default: dragHover = nil
        }
    }
    func finishOrganizerDrag() {
        withAnimation(.easeInOut(duration: 0.18)) {
            switch dragHover {
            case let .project(target, after): if let source = draggingProject { _ = placeProject(source, relativeTo: target, after: after) }
            case let .folder(target, after): if let source = draggingFolder { _ = moveFolder(source, relativeTo: target, after: after) }
            case let .insideFolder(id): if let source = draggingProject { _ = dropIntoFolder(source, folder: id == Self.ungroupedFolderID ? nil : id) }
            case nil: break
            }
            draggingProject = nil; draggingFolder = nil; dragScope = nil; dragHover = nil; dragInitialFrames = [:]
        }
    }
}
