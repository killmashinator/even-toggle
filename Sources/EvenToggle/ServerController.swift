//
//  ServerController.swift
//  The brain of the app. Holds your settings (saved automatically) and
//  starts/stops the `even-terminal` server as a child process.
//
//  Mental model: this is like typing the `even-terminal ...` command for you,
//  with your saved port/folder/model filled in — and killing it when you
//  toggle off. even-terminal reads its own pairing token from
//  ~/.even-terminal/config.json (this app never stores or passes it). Because the token and port never change, the host you paired on
//  your glasses keeps working across restarts. Pair once, reuse forever.
//
//  IMPORTANT (why this file is more than a one-liner): a GUI app launched from
//  Finder does NOT inherit your Terminal's PATH. Tools installed via nvm, Volta,
//  asdf, fnm, or Homebrew live in directories the app can't see, so `node` and
//  `even-terminal` appear "not found". To fix this for everyone, the app asks
//  your login shell for its real PATH (exactly what Terminal uses) and finds
//  even-terminal automatically. No symlinks or manual paths required.
//

import SwiftUI
import Foundation

@MainActor
final class ServerController: ObservableObject {

    // Live state (drives the menu bar + status line).
    @Published private(set) var isRunning = false
    @Published var lastLog = ""

    // Persisted settings. @AppStorage saves these to disk automatically.
    @AppStorage("port")             var port = "3456"
    @AppStorage("provider")         var provider = "claude"        // "claude" or "codex"
    @AppStorage("model")            var model = "default"          // default|sonnet|opus|haiku|fable|custom
    @AppStorage("customModel")      var customModel = ""
    @AppStorage("projectPath")      var projectPath = ""
    @AppStorage("useTailscale")     var useTailscale = true
    @AppStorage("keepAwake")        var keepAwake = true
    // Leave blank to auto-detect. Only set this to override the detected path.
    @AppStorage("evenTerminalPath") var evenTerminalPath = ""
    // PID of the server we last launched, so a crash/force-quit of this app
    // can't leave it running unnoticed: it's reaped on the next launch.
    @AppStorage("serverPID")        var serverPID = 0

    private var process: Process?
    private var caffeinate: Process?
    private var cachedPATH: String?
    private var signalSources: [DispatchSourceSignal] = []

    init() {
        // Stop the server when the app quits, so it never keeps running orphaned
        // while the menu bar icon says "off".
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        // willTerminate doesn't fire for SIGTERM/SIGINT/SIGHUP (e.g. `kill`,
        // logout edge cases), so handle those too. SIGKILL can't be caught;
        // reapOrphan() covers that on the next launch.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stop() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        reapOrphan()
    }

    /// If a server we launched outlived a previous run of this app, stop it.
    private func reapOrphan() {
        let pid = pid_t(serverPID)
        guard pid > 0 else { return }
        serverPID = 0
        guard kill(pid, 0) == 0, Self.commandLine(of: pid)?.contains("even-terminal") == true else { return }
        kill(pid, SIGTERM)
        lastLog = "Stopped a leftover even-terminal (pid \(pid)) from a previous run."
    }

    private static func commandLine(of pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    static let evenTerminalConfigPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".even-terminal/config.json")

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        // even-terminal reads its pairing token from its own config file.
        guard FileManager.default.fileExists(atPath: Self.evenTerminalConfigPath) else {
            lastLog = "No ~/.even-terminal/config.json yet. Run `even-terminal config` in Terminal first."
            return
        }
        // Validate settings before they reach the command line.
        guard let portNum = Int(port.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(portNum) else {
            lastLog = "Port must be a number from 1024 to 65535."
            return
        }
        guard ["claude", "codex"].contains(provider) else {
            lastLog = "Unknown provider \"\(provider)\". Choose claude or codex."
            return
        }
        if model == "custom",
           customModel.isEmpty || customModel.range(of: #"^[A-Za-z0-9._:\[\]-]{1,100}$"#, options: .regularExpression) == nil {
            lastLog = "Custom model id may only contain letters, digits and . _ : - [ ]"
            return
        }
        guard !projectPath.isEmpty else {
            lastLog = "Choose a project folder in Settings first."
            return
        }

        // 1) Figure out the real PATH (same as your Terminal), then find the CLI.
        let path = Self.trustedPATH(resolvedPATH())
        guard let etPath = resolveEvenTerminal(searchPATH: path) else {
            lastLog = """
            Couldn't find even-terminal. Install it with:
              npm install -g @evenrealities/even-terminal
            or set its full path in Settings (run:  which even-terminal ).
            """
            return
        }
        // Remember what we found so the Settings field shows it.
        if evenTerminalPath != etPath { evenTerminalPath = etPath }

        let project = (projectPath as NSString).expandingTildeInPath

        // Make sure the folder actually exists before launching.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project, isDirectory: &isDir), isDir.boolValue else {
            lastLog = "Project folder not found:\n  \(project)\nChoose it again in Settings."
            return
        }

        // Read the token only to redact it from captured output; it's never
        // stored, passed, or displayed.
        let knownToken = LogRedactor.tokenFromConfig(atPath: Self.evenTerminalConfigPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: etPath)

        // CRITICAL: a Finder-launched app runs in "/" by default. Set the working
        // directory explicitly so Claude Code actually opens in your project —
        // passing -d alone isn't enough if the inner process uses its own cwd.
        p.currentDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)

        // Build the same command you'd type by hand:
        //   even-terminal --provider claude -p <port> -d <folder> [--tailscale]
        // No -t: even-terminal takes the token from ~/.even-terminal/config.json,
        // so it never shows up in argv (visible to `ps`) or in this app's defaults.
        var args = ["--provider", provider, "-p", String(portNum), "-d", project]
        if useTailscale { args.append("--tailscale") }
        p.arguments = args

        // Give the child the real PATH, with even-terminal's own directory first
        // (that's where `node` lives for nvm/Volta/etc., so the shebang resolves).
        // Pass only what the server and Claude Code need, not this app's whole
        // environment (allowlist; BRIDGE_TOKEN and other secrets never pass).
        let keep: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG",
                                 "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]
        var env = ProcessInfo.processInfo.environment.filter { k, _ in
            keep.contains(k) || k.hasPrefix("LC_")
        }
        env["NO_COLOR"] = "1"   // plain output for the log panel
        let etDir = URL(fileURLWithPath: etPath).deletingLastPathComponent().path
        // Only trusted (not group/world-writable) directories, so a planted
        // `node`/`claude`/`tailscale` earlier in PATH can't be picked up.
        env["PATH"] = Self.trustedPATH(etDir + ":" + path)
        // Belt and braces: a stray BRIDGE_TOKEN would override the config file's token.
        env.removeValue(forKey: "BRIDGE_TOKEN")

        // Model selection. We do TWO things so the choice sticks even on the
        // voice-only glasses (where you can't type /model):
        //   1) set ANTHROPIC_MODEL for this session, and
        //   2) write the model into ~/.claude/settings.json (a saved default
        //      there is respected and can otherwise override the env var).
        // "Default" removes our override so Claude Code decides for itself.
        if model != "default" {
            let chosen = (model == "custom") ? customModel : model
            env["ANTHROPIC_MODEL"] = chosen
            applyModelToClaudeSettings(chosen)
        } else {
            applyModelToClaudeSettings(nil)   // remove the saved default
        }
        p.environment = env

        // Capture output (in memory only, never written to disk) so Settings →
        // Advanced can show errors. Token, pairing URL and QR art are redacted.
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            // even-terminal prints the full token, a pairing URL containing it, and
            // a QR code encoding it. Redact before anything is stored or shown.
            let safe = LogRedactor.redact(text, knownToken: knownToken)
            Task { @MainActor in self?.lastLog = safe }
        }

        // When the process ends (crash, kill, reboot), flip our state back.
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
                self?.caffeinate?.terminate()
                self?.caffeinate = nil
            }
        }

        do {
            try p.run()
            process = p
            serverPID = Int(p.processIdentifier)
            isRunning = true
            let modelNote = (model == "default")
                ? "Model: Claude Code default"
                : "Model: \(model == "custom" ? customModel : model) (via ANTHROPIC_MODEL)"
            lastLog = """
            Started even-terminal on port \(port).
            Folder: \(project)
            \(modelNote)
            """

            // Optionally keep the Mac awake for as long as the server runs.
            // `caffeinate -w <pid>` exits by itself once that pid exits.
            // Tracked so stop() and quit end it too, not only the server's exit.
            if keepAwake {
                let c = Process()
                c.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                c.arguments = ["-s", "-w", String(p.processIdentifier)]
                c.standardOutput = FileHandle.nullDevice
                c.standardError = FileHandle.nullDevice
                if (try? c.run()) != nil { caffeinate = c }
            }
        } catch {
            lastLog = "Failed to start: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        if let p = process, p.isRunning {
            let pid = p.processIdentifier
            p.terminate()
            // Escalate if it ignores SIGTERM, so it can't linger after "off".
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        process = nil
        serverPID = 0
        caffeinate?.terminate()
        caffeinate = nil
        isRunning = false
        lastLog = "Stopped."
    }

    // MARK: - Claude model default

    /// Writes (or removes) the "model" key in ~/.claude/settings.json without
    /// disturbing other settings. Passing nil removes the key. This is what makes
    /// the app's model choice stick on the voice-only glasses, where /model can't
    /// be typed.
    private func applyModelToClaudeSettings(_ model: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir  = home.appendingPathComponent(".claude", isDirectory: true)
        let file = dir.appendingPathComponent("settings.json")

        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let parsed = obj as? [String: Any] {
            dict = parsed
        }

        // Leave the user's Claude settings untouched unless the value changes
        // (avoids rewriting/reformatting it, or replacing a symlink, every start).
        let current = dict["model"] as? String
        let wanted = (model?.isEmpty == false) ? model : nil
        if current == wanted { return }

        if let model, !model.isEmpty {
            dict["model"] = model
        } else {
            dict.removeValue(forKey: "model")
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: dict,
                                                 options: [.prettyPrinted, .sortedKeys])
            try out.write(to: file, options: .atomic)
        } catch {
            NSLog("Could not update ~/.claude/settings.json: \(error)")
        }
    }

    // MARK: - Environment resolution

    /// The PATH your login shell actually uses (so nvm/Volta/Homebrew tools are
    /// visible), merged with sensible fallbacks. Cached after the first call.
    private func resolvedPATH() -> String {
        if let cached = cachedPATH { return cached }
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // A marker lets us ignore any noise a shell's startup files print.
        if let out = Self.loginShellOutput(#"printf '___P___%s' "$PATH""#),
           let r = out.range(of: "___P___") {
            let shellPath = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let merged = shellPath.isEmpty ? fallback : shellPath + ":" + fallback
            cachedPATH = merged
            return merged
        }
        cachedPATH = fallback
        return fallback
    }

    /// Find even-terminal: honor an explicit override, else search the PATH,
    /// else ask the login shell directly.
    private func resolveEvenTerminal(searchPATH: String) -> String? {
        let fm = FileManager.default
        if !evenTerminalPath.isEmpty, fm.isExecutableFile(atPath: evenTerminalPath),
           Self.isTrusted(evenTerminalPath) {
            return evenTerminalPath
        }
        for dir in searchPATH.split(separator: ":") {
            let candidate = String(dir) + "/even-terminal"
            if fm.isExecutableFile(atPath: candidate), Self.isTrusted(candidate) { return candidate }
        }
        if let out = Self.loginShellOutput(#"printf '___E___%s' "$(command -v even-terminal)""#),
           let r = out.range(of: "___E___") {
            let p = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, p.hasPrefix("/"), fm.isExecutableFile(atPath: p), Self.isTrusted(p) { return p }
        }
        return nil
    }

    /// True if `path` (and its symlink target) and every parent directory are
    /// owned by root or this user, never world-writable, and group-writable only
    /// for this user's own group or `admin` (Homebrew's /opt/homebrew is 775 admin).
    static func isTrusted(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        // realpath(3), not NSString.resolvingSymlinksInPath (which strips /private).
        guard let rp = realpath(path, nil) else { return false }
        let resolved = String(cString: rp); free(rp)
        for start in Set([path, resolved]) {
            var p = start
            while true {
                guard let a = try? FileManager.default.attributesOfItem(atPath: p),
                      let owner = a[.ownerAccountID] as? NSNumber,
                      let perms = a[.posixPermissions] as? NSNumber else { return false }
                let isLink = (a[.type] as? FileAttributeType) == .typeSymbolicLink
                if owner.uint32Value != 0 && owner.uint32Value != getuid() { return false }
                let group = (a[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0
                if !isLink && perms.intValue & 0o002 != 0 { return false }
                if !isLink && perms.intValue & 0o020 != 0 && group != 80 && group != getgid() { return false }
                if p == "/" { break }
                p = (p as NSString).deletingLastPathComponent
            }
        }
        return true
    }

    /// Keep only absolute, existing, trusted PATH entries (order preserved, deduped).
    static func trustedPATH(_ path: String) -> String {
        var seen = Set<String>()
        return path.split(separator: ":").map(String.init).filter {
            $0.hasPrefix("/") && seen.insert($0).inserted && isTrusted($0)
        }.joined(separator: ":")
    }

    /// Run a command in the user's login shell and return stdout, with a timeout
    /// so a misbehaving startup file can't hang the app.
    private static func loginShellOutput(_ command: String, timeout: TimeInterval = 5) -> String? {
        // Only a shell listed in /etc/shells; otherwise fall back to zsh.
        let envShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let allowed = ((try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let shell = allowed.contains(envShell) ? envShell : "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", command]   // interactive+login so nvm/rc files load
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()          // discard startup-file noise
        do { try p.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
