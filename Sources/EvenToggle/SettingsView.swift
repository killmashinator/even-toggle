//
//  SettingsView.swift
//  The Settings window. Everything needed to connect lives here, so if you
//  ever reinstall or something breaks, you just re-enter these and you're back.
//

import SwiftUI
import AppKit   // for NSOpenPanel (the native "choose a folder" dialog)

struct SettingsView: View {
    @EnvironmentObject var server: ServerController

    var body: some View {
        Form {
            Section("Connection") {
                HStack {
                    Text("Pairing token: kept by even-terminal in ~/.even-terminal/config.json")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show config") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: ServerController.evenTerminalConfigPath)])
                    }
                }
                TextField("Port", text: $server.port)
                Toggle("Use Tailscale (connect from anywhere)", isOn: $server.useTailscale)
                Toggle("Keep Mac awake while running", isOn: $server.keepAwake)
            }

            Section("Project folder") {
                HStack {
                    TextField("No folder chosen", text: $server.projectPath)
                    Button("Choose…") { chooseFolder() }
                }
                Text("Claude Code works inside this folder and its subfolders.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Model") {
                Picker("Claude model", selection: $server.model) {
                    Text("Default (recommended)").tag("default")
                    Text("Sonnet — everyday coding").tag("sonnet")
                    Text("Opus — hardest problems").tag("opus")
                    Text("Haiku — fast & light").tag("haiku")
                    Text("Fable 5 — long autonomous tasks").tag("fable")
                    Text("Custom…").tag("custom")
                }
                if server.model == "custom" {
                    TextField("Model id (e.g. claude-opus-4-8)", text: $server.customModel)
                }
            }

            Section("Advanced") {
                TextField("Path to even-terminal", text: $server.evenTerminalPath)
                Text("Find it with:  which even-terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text(server.lastLog.isEmpty ? "No output yet." : server.lastLog)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }

    /// Opens the standard macOS folder chooser and stores the pick.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true) // bring the panel to front
        if panel.runModal() == .OK, let url = panel.url {
            server.projectPath = url.path
        }
    }
}
