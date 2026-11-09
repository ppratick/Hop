import SwiftUI

struct GitActions: View {
    @ObservedObject var store: Store
    let project: Project
    var compact = true
    var body: some View {
        let state = store.gitSync[project.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if store.syncing.contains(project.id) {
                    ProgressView().controlSize(.mini)
                    Text("Updating Git…").foregroundStyle(.secondary)
                } else {
                    if project.changes > 0 {
                        Text("\(project.changes) changed").foregroundStyle(.orange)
                        Button("Commit") { store.commitProject = project }.tint(.blue)
                    }
                    if let state, state.ready {
                        if state.incoming > 0 {
                            Text("↓ \(state.incoming) incoming").foregroundStyle(.cyan)
                            if state.outgoing == 0 && project.changes == 0 {
                                Button("Pull") { store.checkRemote(project, pull: true) }.tint(.cyan)
                            }
                        }
                        if state.outgoing > 0 {
                            Text("↑ \(state.outgoing) unpushed").foregroundStyle(.blue)
                            if state.incoming == 0 {
                                Button("Push") { store.pushProject(project) }.tint(.blue)
                            }
                        }
                        if state.incoming == 0 && state.outgoing == 0 && project.changes == 0 {
                            Text("Up to date").foregroundStyle(.green)
                        }
                    } else {
                        Text(state?.detail ?? "Not checked").foregroundStyle(.secondary).lineLimit(1)
                        Button("Check") { store.checkRemote(project) }
                    }
                }
                Spacer(minLength: 0)
            }.buttonStyle(.bordered).controlSize(compact ? .mini : .small)
            if let state, state.ready, state.incoming > 0 {
                if state.outgoing > 0 {
                    Text("Branches diverged. Resolve in your editor before pushing.").foregroundStyle(.orange)
                } else if project.changes > 0 {
                    Text("Commit or stash local edits before pulling.").foregroundStyle(.orange)
                }
            }
        }.font(.system(size: compact ? 10 : 12, weight: .medium)).padding(.horizontal, compact ? 12 : 0).padding(.bottom, compact ? 10 : 0)

    }
}

struct GitCommitSheet: View {
    @ObservedObject var store: Store
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var files: [GitFile] = []
    @State private var selected: Set<String> = []
    @State private var previewFile: String?
    @State private var message = ""
    @State private var error = ""
    @State private var busy = true
    @State private var acknowledged = false
    @State private var remote = GitSyncState()
    @State private var checkingRemote = true
    var warning: Bool { !checkingRemote && (!remote.ready || remote.incoming > 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Commit changes").font(.system(size: 22, weight: .semibold))
                    Text(store.name(project)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("Choose the files to include in this commit.").font(.callout).foregroundStyle(.secondary)
            if checkingRemote {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Checking remote…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if warning {
                Text(remote.ready ? "↓ \(remote.incoming) remote commits haven’t been pulled. Committing now may create diverged branches." : "Remote status could not be verified: \(remote.detail)")
                    .font(.callout).foregroundStyle(.orange)
                Toggle("I understand; commit local changes", isOn: $acknowledged)
            }
            HStack {
                Text("\(selected.count) of \(files.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button(selected.count == files.count ? "Deselect All" : "Select All") {
                    selected = selected.count == files.count ? [] : Set(files.map(\.path))
                }.disabled(busy || files.isEmpty)
            }.font(.caption)
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files) { file in
                            HStack(spacing: 8) {
                                Toggle("Include " + file.path, isOn: Binding(get: { selected.contains(file.path) }, set: { on in
                                    if on { selected.insert(file.path) } else { selected.remove(file.path) }
                                })).labelsHidden().toggleStyle(.checkbox)
                                Button { previewFile = file.path } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((file.path as NSString).lastPathComponent)
                                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                        let folder = (file.path as NSString).deletingLastPathComponent
                                        if !folder.isEmpty {
                                            Text(folder).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Preview " + file.path)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(previewFile == file.path ? Color.blue.opacity(0.16) : .clear)
                            if file.id != files.last?.id { Divider().padding(.leading, 36) }
                        }
                    }
                }.frame(width: 245)
                Divider()
                if let previewFile {
                    GitDiffPreview(projectPath: project.path, file: previewFile)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(files.isEmpty ? "No changed files" : "Choose a file to preview")
                        .foregroundStyle(.secondary).font(.callout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 270)
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            .disabled(busy)
            VStack(alignment: .leading, spacing: 8) {
                Text("Commit message").font(.system(size: 12, weight: .medium))
                TextField("Describe what changed…", text: $message, axis: .vertical)
                    .lineLimit(3...4).textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(12)
                    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)))
                    .disabled(busy)
                Text("Includes all staged and unstaged edits in the selected files.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Commit \(selected.count) files") {
                    busy = true
                    store.syncing.insert(project.id)
                    let chosen = Array(selected), text = message
                    Task {
                        let latest = await Task.detached { checkGitSync(project.path) }.value
                        store.remoteFetchDates[project.id] = Date()
                        store.gitSync[project.id] = latest
                        if latest.ready { store.lastRemoteChecked = Date() }
                        if (latest.incoming > remote.incoming || (!latest.ready && remote.ready)) {
                            remote = latest; acknowledged = false; busy = false
                            store.syncing.remove(project.id)
                            error = "Remote status changed. Review the warning before committing."
                            return
                        }
                        let result = await Task.detached { commitGitFiles(project.path, files: chosen, message: text) }.value
                        store.syncing.remove(project.id)
                        busy = false
                        if result.0 == 0 { store.refresh(); dismiss() }
                        else { error = result.1 }
                    }
                }.buttonStyle(.borderedProminent).disabled(busy || checkingRemote || selected.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (warning && !acknowledged))
            }
        }.padding(24).frame(width: 820).disabled(store.syncing.contains(project.id) && !busy)
            .interactiveDismissDisabled(busy)
            .task {
                let loadedFiles = await Task.detached { changedGitFiles(project.path) }.value
                guard !Task.isCancelled else { return }
                files = loadedFiles; selected = Set(files.map(\.path)); previewFile = files.first?.path; busy = false
                let checked = await Task.detached { checkGitSync(project.path) }.value
                guard !Task.isCancelled else { return }
                remote = checked; checkingRemote = false
                store.remoteFetchDates[project.id] = Date(); store.gitSync[project.id] = checked
                if checked.ready { store.lastRemoteChecked = Date() }
            }
    }
}

private struct GitDiffPreview: View {
    let projectPath: String
    let file: String
    @State private var diff = AttributedString()
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(file)
                Text("Compared with HEAD · staged + unstaged")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(diff).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .task(id: file) {
            loading = true
            let text = await Task.detached(priority: .utility) { gitFileDiff(projectPath, file: file) }.value
            guard !Task.isCancelled else { return }
            var styled = AttributedString()
            for line in text.components(separatedBy: "\n") {
                var value = AttributedString(line + "\n")
                if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") { value.foregroundColor = .secondary }
                else if line.hasPrefix("+") { value.foregroundColor = .green }
                else if line.hasPrefix("-") { value.foregroundColor = .red }
                styled.append(value)
            }
            diff = styled
            loading = false
        }
    }
}
