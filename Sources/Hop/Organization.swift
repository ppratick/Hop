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
struct ProjectSwipeSurface: NSViewRepresentable {
    @ObservedObject var store: Store
    let project: Project
    @Binding var swipeOffset: CGFloat
    func makeNSView(context: Context) -> ProjectSwipeView { ProjectSwipeView() }
    func updateNSView(_ view: ProjectSwipeView, context: Context) {
        view.swipeOffset = swipeOffset
        view.onSwipe = { offset, ended in
            if !ended {
                store.swipeProject = project.id
                if offset < 0 && store.expanded == project.id { store.expanded = nil }
                swipeOffset = offset
            } else {
                withAnimation(.snappy(duration: 0.2)) { swipeOffset = offset < -54 ? -144 : 0 }
                if swipeOffset == 0 { store.swipeProject = nil }
            }
        }
        view.toolTip = "Drag to organize. Swipe left to hide or remove."
    }
}
final class ProjectSwipeView: NSView {
    var onSwipe: ((CGFloat, Bool) -> Void)?
    var swipeOffset: CGFloat = 0
    private var scrollMonitor: Any?
    private var swipeTracking = false
    private var verticalScrolling = false
    private var swipeStart: CGFloat = 0
    private var swipeDistance: CGFloat = 0
    private var swipeEnd: DispatchWorkItem?
    private weak var gestureHost: NSView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if gestureHost !== window?.contentView {
            gestureHost = window?.contentView
        }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }; scrollMonitor = nil
        if window != nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }; return self.handleSwipe(event)
            }
        }
    }
    deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }
    private func finishSwipe() {
        guard swipeTracking else { return }
        swipeTracking = false; verticalScrolling = false
        onSwipe?(max(-144, min(0, swipeStart + swipeDistance)), true)
    }
    private func handleSwipe(_ event: NSEvent) -> NSEvent? {
        guard onSwipe != nil, event.window === window, event.momentumPhase.isEmpty else { return event }
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        if ended {
            if swipeTracking { swipeEnd?.cancel(); finishSwipe(); return nil }
            verticalScrolling = false; return event
        }
        if event.phase.contains(.began) { verticalScrolling = false }
        if !swipeTracking {
            guard !isHiddenOrHasHiddenAncestor, visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return event }
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) * 1.2 { verticalScrolling = true }
            guard !verticalScrolling, abs(event.scrollingDeltaX) > max(1, abs(event.scrollingDeltaY) * 1.2) else { return event }
            var hit = gestureHost?.hitTest(gestureHost?.convert(event.locationInWindow, from: nil) ?? .zero)
            while let view = hit, view !== gestureHost {
                if view is NSTextView || view is NSTextField { return event }
                hit = view.superview
            }
            swipeTracking = true; swipeStart = swipeOffset; swipeDistance = 0
        }
        swipeDistance += event.scrollingDeltaX
        onSwipe?(max(-144, min(0, swipeStart + swipeDistance)), false)
        swipeEnd?.cancel()
        if event.phase.isEmpty {
            let end = DispatchWorkItem { [weak self] in self?.finishSwipe() }; swipeEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
        }
        return nil
    }
}
struct ProjectDropTarget: ViewModifier {
    @ObservedObject var store: Store
    let project: Project
    var scope = "menu"
    var allowsDragging = true
    var edge: Int? {
        guard case let .project(id, after) = store.dragHover, id == project.id else { return nil }
        return after ? 1 : 0
    }
    @State private var swipeOffset: CGFloat = 0
    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            if swipeOffset < 0 {
                HStack(spacing: 0) {
                    swipeButton("Hide", icon: "eye.slash", color: .orange) { store.hideProject(project); swipeOffset = 0 }
                    swipeButton("Remove", icon: "trash", color: .red) { store.removeProject(project); swipeOffset = 0 }
                }.frame(width: 144).frame(maxHeight: .infinity)
            }
            content
                .background(ProjectSwipeSurface(store: store, project: project, swipeOffset: $swipeOffset))
                .offset(x: swipeOffset)
                .simultaneousGesture(TapGesture().onEnded { if swipeOffset != 0 { withAnimation(.snappy(duration: 0.2)) { swipeOffset = 0 } } })
        }.clipShape(RoundedRectangle(cornerRadius: 9))
            .opacity(store.draggingProject == project.id ? 0.4 : 1)
            .overlay(alignment: .top) { if edge == 0 { insertion.offset(y: -4) } }
            .overlay(alignment: .bottom) { if edge == 1 { insertion.offset(y: 4) } }
            .modifier(OrganizerGeometry(item: .project(project.id), scope: scope))
            .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(scope))
                .onChanged { value in swipeOffset = 0; store.updateOrganizerDrag(.project(project.id), scope: scope, point: value.location) }
                .onEnded { value in store.updateOrganizerDrag(.project(project.id), scope: scope, point: value.location); store.finishOrganizerDrag() }, including: allowsDragging ? .all : .none)
            .onChange(of: store.swipeProject) { _, value in if value != project.id { withAnimation(.snappy(duration: 0.2)) { swipeOffset = 0 } } }
    }
    func swipeButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 15)); Text(title).font(.system(size: 10, weight: .semibold)) }
                .foregroundStyle(.white).frame(width: 72).frame(maxHeight: .infinity).background(color).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    var insertion: some View {
        HStack(spacing: 0) { Circle().fill(.primary).frame(width: 6, height: 6); Rectangle().fill(.primary).frame(height: 2) }.allowsHitTesting(false)
    }
}
struct FolderHeader: View {
    @ObservedObject var store: Store
    let folder: ProjectFolder?
    let count: Int
    var compact = false
    var targeted: Bool { store.dragHover == .insideFolder(groupID) }
    var folderEdge: Int? {
        guard case let .folder(id, after) = store.dragHover, id == groupID else { return nil }
        return after ? 1 : 0
    }
    var scope: String { compact ? "settings" : "menu" }
    var groupID: String { folder?.id ?? Store.ungroupedFolderID }
    var collapsed: Bool { store.disk.collapsedFolders.contains(groupID) }
    var body: some View {
        Button { withAnimation { store.toggleFolder(groupID) } } label: {
            HStack(spacing: 9) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 10)
                Image(systemName: folder == nil ? "square.grid.2x2" : targeted ? "folder.badge.plus" : "folder.fill").foregroundStyle(targeted ? Color.primary : Color.secondary)
                Text(folder?.title ?? "Ungrouped").lineLimit(2)
                Spacer(minLength: 0)
                if targeted { Image(systemName: "arrow.down.to.line").foregroundStyle(.primary) }
                else { Text("\(count)").foregroundStyle(.secondary).font(.system(size: 11)) }
            }.font(.system(size: compact ? 14 : 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: compact ? 30 : 34, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, compact ? 10 : 12)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .opacity(store.draggingFolder == groupID ? 0.4 : 1)
            .background(targeted ? Color.primary.opacity(0.16) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: compact ? 9 : 10))
            .overlay { if targeted { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).allowsHitTesting(false) } }
            .contextMenu {
                Button(collapsed ? "Expand" : "Collapse") { store.toggleFolder(groupID) }
                if let folder {
                    Button("Rename…") { store.askForFolder(folder) }
                    Button("Remove folder") { store.removeFolder(folder.id) }
                }
            }
            .overlay(alignment: .top) { if folderEdge == 0 { folderInsertion.offset(y: -4) } }
            .overlay(alignment: .bottom) { if folderEdge == 1 { folderInsertion.offset(y: 4) } }
            .modifier(OrganizerGeometry(item: .folder(groupID), scope: scope))
            .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(scope))
                .onChanged { value in store.updateOrganizerDrag(.folder(groupID), scope: scope, point: value.location) }
                .onEnded { value in store.updateOrganizerDrag(.folder(groupID), scope: scope, point: value.location); store.finishOrganizerDrag() })
    }
    var folderInsertion: some View {
        HStack(spacing: 0) { Circle().fill(.primary).frame(width: 6, height: 6); Rectangle().fill(.primary).frame(height: 2) }.allowsHitTesting(false)
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
                    if store.dragScope == scope, let title = store.dragTitle {
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
    func updateOrganizerDrag(_ item: OrganizerItem, scope: String, point: CGPoint) {
        switch item {
        case .project(let id): draggingProject = id; draggingFolder = nil
        case .folder(let id): draggingFolder = id; draggingProject = nil
        }
        swipeProject = nil; dragScope = scope; dragPoint = point
        let target = dragFrames[scope]?.values.filter { $0.item != item && $0.rect.contains(point) }.min { $0.rect.height < $1.rect.height }
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
            draggingProject = nil; draggingFolder = nil; dragScope = nil; dragHover = nil
        }
    }
}
