import Foundation
import AppKit
import Darwin

struct TerminalRecord: Codable {
    var pid: Int32
    var seconds: UInt64
    var microseconds: UInt64
    var exitStatus: Int32?
    static func identity(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
    var isAlive: Bool {
        guard exitStatus == nil, let info = Self.identity(pid) else { return false }
        return info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == microseconds && info.pbi_pgid == UInt32(pid)
    }
    static func read(_ url: URL) -> TerminalRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
func terminalAppleScript(_ command: String) -> String {
    let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return """
    set terminalWasRunning to application "Terminal" is running
    tell application "Terminal"
        if terminalWasRunning then
            do script "\(quoted)"
        else
            activate
            if (count of windows) > 0 then
                do script "\(quoted)" in selected tab of front window
            else
                do script "\(quoted)"
            end if
        end if
        activate
    end tell
    """
}
func executeInTerminal(_ command: String) async -> String {
    let script = terminalAppleScript(command)
    return await Task.detached {
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error?[NSAppleScript.errorMessage] as? String ?? ""
    }.value
}
// Runs as the foreground job in Terminal. Children share this job's process group,
// so Ctrl-C and Hop's Stop both reach the service without touching other tabs.
func runTerminalService(command: String, state: URL) -> Never {
    guard FileManager.default.fileExists(atPath: state.path) else { exit(0) }
    let pid = getpid()
    if getpgrp() != pid && setpgid(0, 0) != 0 { fputs("Couldn’t isolate service process.\n", stderr); exit(1) }
    guard let info = TerminalRecord.identity(pid) else { exit(1) }
    var record = TerminalRecord(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    func save() { if let data = try? JSONEncoder().encode(record) { try? data.write(to: state, options: .atomic) } }
    save()
    let signals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
    for sig in signals { signal(sig, SIG_IGN) }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    var defaults = sigset_t(); sigemptyset(&defaults)
    for sig in signals { sigaddset(&defaults, sig) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
    let args = ["/bin/zsh", "-l", "-c", command]
    let argv = args.map { strdup($0) } + [nil]
    defer { for p in argv { free(p) }; posix_spawnattr_destroy(&attributes) }
    let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
    var child: pid_t = 0
    print("$ \(command)"); fflush(stdout)
    let result = argv.withUnsafeBufferPointer { args in
        environment.withUnsafeBufferPointer { env in posix_spawn(&child, "/bin/zsh", nil, &attributes, args.baseAddress!, env.baseAddress!) }
    }
    guard result == 0 else { record.exitStatus = result; save(); exit(result) }
    var status: Int32 = 0
    while waitpid(child, &status, 0) < 0 { if errno != EINTR { break } }
    let code: Int32 = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f)
    record.exitStatus = code; save()
    print("\nService stopped\(code == 0 ? "" : " (exit \(code))").")
    exit(code)
}
