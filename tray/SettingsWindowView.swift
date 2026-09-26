import AppKit
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject var model: PanelModel
    let actions: PanelActions
    @State private var cliInstallMessage: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill").font(.system(size: 17)).foregroundStyle(Ink.secondary)
                Text("Settings").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { actions.closeSettings() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .frame(height: 62)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if Bundle.main.object(forInfoDictionaryKey: "N2FleetQA") as? Bool == true {
                        FleetSyncSettings()
                    }

                    section("GENERAL", subtitle: "Choose where N2 Agents opens your sessions.") {
                        if let terminals = model.data?.terminals, !terminals.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(Array(terminals.enumerated()), id: \.element) { index, name in
                                    Button { actions.setPreferredTerminal(name) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "terminal").frame(width: 18).foregroundStyle(Ink.secondary)
                                            Text(name)
                                            Spacer()
                                            if index == 0 { Image(systemName: "checkmark").foregroundStyle(Ink.link) }
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.horizontal, 13)
                                        .frame(height: 42)
                                    }
                                    .buttonStyle(.plain)
                                    if index < terminals.count - 1 { Divider().padding(.leading, 41) }
                                }
                            }
                            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            row("Terminal", detail: "No supported terminal found")
                        }
                    }

                    section("COMMAND LINE", subtitle: "Use agents and profile commands from any terminal.") {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("N2 Agents CLI")
                                Text(cliInstallMessage ?? "Adds agents to a directory on your PATH.")
                                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                            }
                            Spacer()
                            Button("Install CLI") {
                                cliInstallMessage = actions.installCLI()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 13).frame(minHeight: 58)
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    section("UPDATES", subtitle: "Choose which N2 Agents releases you receive.") {
                        VStack(spacing: 0) {
                            ForEach(UpdateChannel.allCases, id: \.self) { channel in
                                Button { actions.setUpdateChannel(channel) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: channel.symbol).frame(width: 18).foregroundStyle(Ink.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(channel.rawValue.capitalized)
                                            Text(channel == .stable ? "Recommended releases" : "Earlier builds and fixes")
                                                .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                                        }
                                        Spacer()
                                        if UpdateChannel.selected() == channel {
                                            Image(systemName: "checkmark").foregroundStyle(Ink.link)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 13)
                                    .frame(height: 54)
                                }
                                .buttonStyle(.plain)
                                if channel != UpdateChannel.allCases.last { Divider().padding(.leading, 41) }
                            }
                        }
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    section("KEYBOARD", subtitle: "Open the menu bar panel from any app.") {
                        HStack {
                            Label("Global shortcut", systemImage: "keyboard")
                            Spacer()
                            Text(actions.panelShortcut ?? "Not set").foregroundStyle(Ink.secondary)
                            Button("Change…") { actions.setPanelShortcut() }
                        }
                        .padding(.horizontal, 13).frame(height: 46)
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    section("ABOUT", subtitle: "N2 Agents keeps your AI lab profiles in sync.") {
                        VStack(spacing: 0) {
                            row("Version", detail: version)
                            Divider().padding(.leading, 13)
                            HStack {
                                Label("Software updates", systemImage: "arrow.down.circle")
                                Spacer()
                                Button("Check Now…") { actions.checkForUpdates() }
                            }
                            .padding(.horizontal, 13).frame(height: 46)
                        }
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 500, height: 600)
        .foregroundStyle(.primary)
    }

    private func section<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Ink.secondary)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            content()
        }
    }

    private func row(_ title: String, detail: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(Ink.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 13)
        .frame(height: 46)
    }
}
