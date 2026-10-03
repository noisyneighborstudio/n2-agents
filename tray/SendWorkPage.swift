import AppKit
import SwiftUI

// Send work to another Mac: the work, what it needs, and where it may run,
// then the CLI's own plan before Send. The draft lives on the model, so
// closing the panel mid-sentence loses nothing.
struct SendWorkPage: View {
    @ObservedObject var model: PanelModel
    let actions: FleetActions

    private var draft: WorkDraft { model.workDraft }

    /// Any edit returns the page to editing: a plan is only true of the draft it was made for.
    private func edit<T>(_ key: WritableKeyPath<WorkDraft, T>) -> Binding<T> {
        Binding(get: { model.workDraft[keyPath: key] }, set: { value in
            model.workDraft[keyPath: key] = value
            if model.workDraft.state != .sending { model.workDraft.state = .editing }
        })
    }

    var body: some View {
        let d = draft
        let machines = model.fleet?.destinations.map(\.machine) ?? []
        let agents = model.data?.snapshot.installedVendors ?? []
        VStack(alignment: .leading, spacing: 0) {
            NavBar(title: String(localized: "Send Work", comment: "Send Work page title"), back: { model.pop() }) {
                Text(verbatim: model.parentTitle).font(.system(size: 13)).foregroundStyle(Ink.link).lineLimit(1)
            } trailing: { EmptyView() }
            FittingScroll(maxHeight: PanelView.bodyLimit) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: edit(\.shell)) {
                        Text("Agent task", comment: "Send Work: the work is a prompt").tag(false)
                        Text("Shell command", comment: "Send Work: the work is a command").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    field(d.shell ? String(localized: "Command", comment: "Send Work field") : String(localized: "Task", comment: "Send Work field")) {
                        TextEditor(text: edit(\.task))
                            .font(.system(size: 12.5, design: d.shell ? .monospaced : .default))
                            .scrollContentBackground(.hidden)
                            .frame(height: 76)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Ink.surface))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.cardEdge, lineWidth: 0.5))
                            .accessibilityLabel(String(localized: "Task or command", comment: "Send Work field"))
                    }
                    field(String(localized: "Workspace", comment: "Send Work field")) {
                        TextField(String(localized: "Optional folder; uncommitted changes go too", comment: "Send Work placeholder"), text: edit(\.workspace))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    }
                    field(String(localized: "Context file", comment: "Send Work field")) {
                        TextField(String(localized: "Optional file of decisions and progress", comment: "Send Work placeholder"), text: edit(\.contextFile))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    }
                    field(String(localized: "Required tools", comment: "Send Work field")) {
                        TextField(String(localized: "Optional: node,git", comment: "Send Work placeholder"), text: edit(\.requirements))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    }
                    HStack(spacing: 8) {
                        pin(String(localized: "Fastest eligible Mac", comment: "Send Work: no machine pin"), selection: edit(\.machine),
                            options: machines.map { ($0, $0) })
                        pin(String(localized: "Best eligible agent", comment: "Send Work: no agent pin"), selection: edit(\.agent),
                            options: agents.map { ($0.id, $0.label) })
                    }
                    Text("Without a workspace, work runs in an empty folder. Files written to $N2_FLEET_OUTPUTS can be fetched or copied on when you ask.",
                         comment: "Send Work: what travels and what comes back")
                        .font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                    outcome(d.state)
                    HStack(spacing: 8) {
                        Button(String(localized: "Plan", comment: "Send Work: show where it would run")) {
                            if let spec = d.spec { actions.fleetPlan(spec) }
                        }
                        .buttonStyle(WideButton())
                        .disabled(d.spec == nil || d.state == .planning || d.state == .sending)
                        Button(String(localized: "Send", comment: "Send Work: send it")) {
                            if let spec = d.spec { actions.fleetDispatch(spec) }
                        }
                        .buttonStyle(WideButton(prominent: true))
                        .disabled(d.spec == nil || d.state == .sending)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder private func outcome(_ state: WorkDraft.State) -> some View {
        switch state {
        case .planning, .sending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(state == .planning ? String(localized: "Asking the fleet…", comment: "Send Work: planning")
                                        : String(localized: "Sending…", comment: "Send Work: sending"))
            }
            .font(.system(size: 12)).foregroundStyle(Ink.secondary)
        case .planned(let plan):
            VStack(alignment: .leading, spacing: 4) {
                if plan.candidates.isEmpty {
                    Label(String(localized: "Nothing can run this as asked.", comment: "Send Work: empty plan"), systemImage: "xmark.circle")
                        .foregroundStyle(Ink.red)
                }
                ForEach(plan.candidates.prefix(3), id: \.rank) { c in
                    HStack(spacing: 8) {
                        Text(verbatim: "\(c.rank)").monospacedDigit().foregroundStyle(Ink.tertiary).frame(width: 14)
                        Text(verbatim: c.machine).fontWeight(c.rank == 1 ? .semibold : .regular)
                        Text(verbatim: model.data?.snapshot.vendor(c.agent)?.label ?? c.agent).foregroundStyle(Ink.secondary)
                        Spacer()
                        Text(verbatim: c.eta).monospacedDigit().foregroundStyle(Ink.tertiary)
                    }
                }
                ForEach(plan.excluded.prefix(3), id: \.self) { line in
                    Text(verbatim: FleetWords.exclusion(line)).font(.system(size: 11.5)).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
            }
            .font(.system(size: 12.5))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Ink.surface))
        case .sent(let receipt):
            Label { Text(receipt.isEmpty ? String(localized: "Sent.", comment: "Send Work: done") : FleetWords.receipt(receipt)) }
                icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.green) }
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.yellow) }
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case .editing:
            EmptyView()
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title).textCase(.uppercase).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary)
            content()
        }
    }

    /// Unpinned (the fleet ranks it) or one choice, as a native menu.
    private func pin(_ none: String, selection: Binding<String?>, options: [(id: String, label: String)]) -> some View {
        Menu {
            Button(none) { selection.wrappedValue = nil }
            Divider()
            ForEach(options, id: \.id) { o in Button(o.label) { selection.wrappedValue = o.id } }
        } label: {
            Text(verbatim: options.first { $0.id == selection.wrappedValue }?.label ?? none).font(.system(size: 12)).lineLimit(1)
        }
        .menuStyle(.borderedButton)
        .frame(maxWidth: .infinity)
    }
}
