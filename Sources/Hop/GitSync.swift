import Foundation

struct GitSyncState {
    var incoming = 0
    var outgoing = 0
    var detail = "Checking remote…"
    var ready = false
}

func syncGit(_ path: String, _ arguments: [String], trimOutput: Bool = true) -> (Int32, String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=10"
    process.environment = environment
    process.standardOutput = pipe; process.standardError = pipe
    do {
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        let output = String(decoding: data, as: UTF8.self)
        return (process.terminationStatus, (arguments.contains("-z") || !trimOutput) ? output : output.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch { return (-1, error.localizedDescription) }
}

func checkGitSync(_ path: String, fetch: Bool = true) -> GitSyncState {
    let upstream = syncGit(path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
    guard upstream.0 == 0 else { return GitSyncState(detail: "No upstream branch") }
    if fetch {
        let fetched = syncGit(path, ["fetch", "--quiet"])
        guard fetched.0 == 0 else { return GitSyncState(detail: "Remote unavailable · retry to check") }
    }
    let counts = syncGit(path, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
    let values = counts.1.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
    guard counts.0 == 0, values.count == 2 else { return GitSyncState(detail: "Couldn’t compare branches") }
    return GitSyncState(incoming: values[1], outgoing: values[0], detail: "Up to date", ready: true)
}

extension Store {
    func checkRemote(_ project: Project, pull: Bool = false, force: Bool = true, minimumInterval: Int = 300) {
        guard !project.branch.isEmpty, !syncing.contains(project.id) else { return }
        let fetch = shouldFetchRemote(lastAttempt: remoteFetchDates[project.id], force: force || pull, minimumInterval: minimumInterval)
        if fetch { remoteFetchDates[project.id] = Date() }
        syncing.insert(project.id)
        Task {
            let result = await Task.detached(priority: .utility) { () -> (GitSyncState, String?) in
                if pull {
                    let dirty = syncGit(project.path, ["status", "--porcelain"])
                    guard dirty.0 == 0, dirty.1.isEmpty else {
                        return (checkGitSync(project.path), "Commit or stash local changes before pulling.")
                    }
                    let pulled = syncGit(project.path, ["pull", "--ff-only", "--no-rebase"])
                    guard pulled.0 == 0 else {
                        return (checkGitSync(project.path), "Pull failed. Hop hasn’t reset or stashed your work. " + pulled.1)
                    }
                }
                return (checkGitSync(project.path, fetch: fetch), nil)
            }.value
            if !fetch, gitSync[project.id]?.ready == false {
                // Do not turn an unverified remote state into "Up to date" using stale refs.
            } else { gitSync[project.id] = result.0 }
            if fetch && result.0.ready { lastRemoteChecked = Date() }
            syncing.remove(project.id)
            if let error = result.1 { message = error }
            if pull { refresh() }
        }
    }
}

struct GitFile: Identifiable {
    var id: String { path }
    let path: String
}

func changedGitFiles(_ path: String) -> [GitFile] {
    // --no-renames represents renames as a deletion and addition, both selectable.
    let tracked = syncGit(path, ["diff", "--name-only", "--no-renames", "-z", "--"])
    let staged = syncGit(path, ["diff", "--cached", "--name-only", "--no-renames", "-z", "--"])
    let untracked = syncGit(path, ["ls-files", "--others", "--exclude-standard", "-z"])
    return Set((tracked.1 + "\0" + staged.1 + "\0" + untracked.1).split(separator: "\0").map(String.init))
        .filter { !$0.isEmpty }.sorted().map { GitFile(path: $0) }
}

func commitGitFiles(_ path: String, files: [String], message: String) -> (Int32, String) {
    guard !files.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (-1, "Select files and enter a commit message.")
    }
    let conflicts = syncGit(path, ["diff", "--name-only", "--diff-filter=U"])
    guard conflicts.0 == 0, conflicts.1.isEmpty else { return (-1, "Resolve merge conflicts in your editor first.") }
    // Literal pathspecs prevent filenames from being interpreted as Git patterns.
    let paths = files.map { ":(literal)" + $0 }
    let staged = syncGit(path, ["add", "--all", "--"] + paths)
    guard staged.0 == 0 else { return staged }
    return syncGit(path, ["commit", "--only", "-m", message, "--"] + paths)
}

func pushGit(_ path: String) -> (Int32, String) {
    let state = checkGitSync(path)
    guard state.ready else { return (-1, state.detail) }
    guard state.incoming == 0 else { return (-1, "Remote commits are incoming. Pull or resolve diverged branches in your editor before pushing.") }
    let branch = syncGit(path, ["symbolic-ref", "--quiet", "--short", "HEAD"])
    guard branch.0 == 0 else { return (-1, "Select a branch before pushing.") }
    let remote = syncGit(path, ["config", "--get", "branch." + branch.1 + ".remote"])
    let destination = syncGit(path, ["config", "--get", "branch." + branch.1 + ".merge"])
    guard remote.0 == 0, destination.0 == 0 else { return (-1, "Configure an upstream branch in your editor first.") }
    return syncGit(path, ["push", "--", remote.1, "HEAD:" + destination.1])
}

extension Store {
    func pushProject(_ project: Project) {
        guard !syncing.contains(project.id) else { return }
        syncing.insert(project.id)
        Task {
            let result = await Task.detached { pushGit(project.path) }.value
            message = result.0 == 0 ? "Pushed successfully." : result.1
            syncing.remove(project.id)
            checkRemote(project)
            refresh()
        }
    }
}

func shouldFetchRemote(lastAttempt: Date?, now: Date = Date(), force: Bool = false, minimumInterval: Int = 300) -> Bool {
    force || (minimumInterval > 0 && (lastAttempt.map { now.timeIntervalSince($0) >= Double(minimumInterval) } ?? true))
}

func localProjectStatus(_ project: Project) -> Project {
    var updated = project
    guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.path).appendingPathComponent(".git").path) else { return updated }
    let branch = capture("/usr/bin/git", ["--no-optional-locks", "-C", project.path, "branch", "--show-current"])
    let status = capture("/usr/bin/git", ["--no-optional-locks", "-C", project.path, "status", "--porcelain", "--untracked-files=normal"])
    updated.branch = branch.isEmpty ? "Detached HEAD" : branch
    updated.changes = status.isEmpty ? 0 : status.components(separatedBy: "\n").count
    return updated
}

func gitFileDiff(_ root: String, file: String) -> String {
    let base = URL(fileURLWithPath: root).standardizedFileURL
    let url = base.appendingPathComponent(file).standardizedFileURL
    guard url.path.hasPrefix(base.path + "/") else { return "This file is outside the project." }
    let maxSize = 1_000_000
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxSize {
        return "This file is too large for an inline preview. Review it in your editor."
    }
    let hasHead = syncGit(root, ["rev-parse", "--verify", "HEAD"]).0 == 0
    let tracked = hasHead && syncGit(root, ["cat-file", "-e", "HEAD:" + file]).0 == 0
    if tracked, let oldSize = Int(syncGit(root, ["cat-file", "-s", "HEAD:" + file]).1), oldSize > maxSize {
        return "The committed file is too large for an inline preview. Review it in your editor."
    }
    let flags = ["--no-ext-diff", "--no-textconv", "--no-color", "--no-renames"]
    let result: (Int32, String)
    if tracked {
        result = syncGit(root, ["diff"] + flags + ["HEAD", "--", ":(literal)" + file], trimOutput: false)
    } else {
        // --no-index represents the entire contents of newly added files.
        guard FileManager.default.fileExists(atPath: url.path) ||
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
            return "No contents to preview (the file may have been removed)."
        }
        result = syncGit(root, ["diff", "--no-index"] + flags + ["--", "/dev/null", url.path], trimOutput: false)
    }
    guard result.0 == 0 || (!tracked && result.0 == 1) else { return "Couldn’t read the diff. Refresh the file list or review this file in your editor." }
    if result.1.isEmpty { return "No changes compared with the last commit." }
    let limit = 120_000
    if result.1.count > limit { return String(result.1.prefix(limit)) + "\n\nPreview truncated. Review the full change in your editor." }
    return result.1
}
