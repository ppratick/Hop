import AppKit
import SwiftUI

enum ProjectPage: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case configure = "Configure"
    var id: Self { self }
}

struct ProjectWorkspace: View {
    @ObservedObject var store: Store
    let project: Project
    @Namespace private var tabSelection
    @State private var hoveredPage: ProjectPage?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                ForEach(ProjectPage.allCases) { page in
                    let selected = store.projectPage == page
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { store.projectPage = page }
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(page.rawValue, systemImage: page == .overview ? "square.grid.2x2" : "slider.horizontal.3")
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Color.blue : hoveredPage == page ? Color.primary : Color.secondary)
                            ZStack {
                                Capsule().fill(.clear).frame(height: 2)
                                if selected {
                                    Capsule().fill(.blue).frame(height: 2)
                                        .matchedGeometryEffect(id: "project-tab", in: tabSelection)
                                }
                            }
                        }.padding(.top, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .onHover { hoveredPage = $0 ? page : nil }
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30).padding(.bottom, 18)
            if store.projectPage == .overview {
                ProjectOverview(store: store, project: project)
            } else {
                ProjectSettings(store: store, project: project)
            }
        }
    }
}

struct ProjectOverview: View {
    @ObservedObject var store: Store
    let project: Project
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProjectPlatformBadges(project: project, override: store.prefs(project).platformOverride)
                    Spacer()
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
                    } label: { Label("Show in Finder", systemImage: "folder") }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }.padding(.horizontal, 2)
                if !project.branch.isEmpty {
                    GeneralSettingsCard(title: "Git", subtitle: "Local changes and remote updates.", icon: "arrow.triangle.branch") {
                        HStack {
                            Label(project.branch, systemImage: "arrow.triangle.branch").fontWeight(.medium)
                            Spacer()
                            Label(project.changes == 0 ? "Working tree clean" : "\(project.changes) changed",
                                  systemImage: project.changes == 0 ? "checkmark.circle" : "pencil.circle")
                                .foregroundStyle(project.changes == 0 ? Color.secondary : Color.orange)
                        }
                        GitActions(store: store, project: project, compact: false)
                        HStack {
                            Spacer()
                            Button("Check for updates") { store.checkRemote(project) }.disabled(store.syncing.contains(project.id))
                        }.font(.system(size: 11))
                    }
                }
                if project.xcode != nil {
                    GeneralSettingsCard(title: "Build & install", subtitle: "Your device, app build, and installation.", icon: project.platforms.contains("macOS") ? "desktopcomputer" : "iphone") {
                        ProjectDeploymentActions(store: store, project: project, compact: false)
                    }
                }
                OpenAIProjectUsageDetails(usage: store.openAI, project: project)
                GeneralSettingsCard(title: "Launch workspace", subtitle: "Choose what opens, then launch it all together.", icon: "arrow.up.forward.app") {
                    ProjectLaunchActions(store: store, p: project)
                }
                GeneralSettingsCard(title: "Where I left off", subtitle: "Your notes for the next session.", icon: "square.and.pencil") {
                    TextField("What’s next for this project?", text: Binding(
                        get: { store.prefs(project).note },
                        set: { value in store.update(project) { $0.note = value } }
                    ), axis: .vertical)
                        .lineLimit(3...6).textFieldStyle(.plain).font(.system(size: 12)).lineSpacing(3)
                        .padding(10).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
}
