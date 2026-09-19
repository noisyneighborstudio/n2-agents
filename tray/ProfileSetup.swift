import AppKit
import SwiftUI

// Profile setup: pick the labs a profile holds, then sign in to each, one at a
// time. It lives in a floating window rather than the panel: sign-in happens in
// a terminal, and a transient popover closes the moment the terminal takes
// focus. The window watches the profile's slots and ticks each lab the moment
// its login lands — nobody comes back to say they're done. Closing it early is
// fine: the unfinished setup surfaces on the profile's card.

enum LabState: Equatable {
    case waiting
    case signingIn
    case signedIn
    case unconfirmed   // the terminal finished, but this lab keeps its login where we can't see
    case failed        // the terminal finished and no login landed
    case skipped
}

/// What the setup window needs from the app; everything with a side effect
/// still goes through the `agents` CLI.
protocol SetupHost: AnyObject {
    func setupCreate(profile: String, vendors: [String], cloneDesktop: Bool) -> String?
    func setupAuthed(profile: String) -> [String: Bool]?
    func setupStartLogin(profile: String, vendor: String)
    func setupCopyLoginCommand(profile: String, vendor: String)
    func setupPending(profile: String, labs: [String]?)
    func setupOpen(profile: String, vendor: String)
    func setupMakeActive(profile: String)
    var setupDesktopInstalled: Bool { get }
    var setupTerminalName: String { get }
}

final class SetupModel: ObservableObject {
    enum Step { case pick, signIn, ready }

    let profile: String
    let isNew: Bool
    let vendors: [Vendor]
    let existing: Set<String>
    let slotDirs: [String: String]
    @Published var step: Step
    @Published var picked: Set<String>
    @Published var labs: [String] = []
    @Published var states: [String: LabState] = [:]
    @Published var busy = false
    @Published var error: String?

    init(profile: String, isNew: Bool, snapshot: Snapshot, resume: [String]?) {
        self.profile = profile
        self.isNew = isNew
        vendors = snapshot.vendors
        slotDirs = snapshot.slotDirs[profile] ?? [:]
        existing = Set(snapshot.profiles.first { $0.name == profile }?.slots.keys.map { $0 } ?? [])
        // Per-process labs start ticked; a swap lab moves every profile, so
        // it is opt-in.
        picked = Set(snapshot.installedVendors.filter { $0.isolation != "swap" }.map(\.id)).union(existing)
        step = resume == nil ? .pick : .signIn
        if let resume { labs = resume }
    }

    func vendor(_ id: String) -> Vendor? { vendors.first { $0.id == id } }
    var newPicks: [String] { vendors.map(\.id).filter { picked.contains($0) && !existing.contains($0) } }
    var current: String? { labs.first { states[$0] == .signingIn } }
    var failed: String? { labs.first { states[$0] == .failed } }
    var done: Int { labs.filter { states[$0] == .signedIn || states[$0] == .unconfirmed }.count }
    var counted: Int { labs.filter { states[$0] != .skipped }.count }
    var finishedLabs: [String] { labs.filter { states[$0] == .signedIn || states[$0] == .unconfirmed } }
}

final class ProfileSetup: NSObject, NSWindowDelegate {
    let model: SetupModel
    private weak var host: SetupHost?
    private var window: GlassWindow?
    private var poll: Timer?
    private var polling = false
    private var waiters: [([String: Bool]?) -> Void] = []
    var onClose: (() -> Void)?

    init(profile: String, isNew: Bool, snapshot: Snapshot, resume: [String]?, host: SetupHost) {
        model = SetupModel(profile: profile, isNew: isNew, snapshot: snapshot, resume: resume)
        self.host = host
        super.init()
    }

    func show() {
        let hosting = NSHostingController(rootView: SetupView(model: model, actions: self))
        hosting.sizingOptions = .preferredContentSize
        // Floating glass that stays when the app deactivates, so it sits above
        // the terminal while you type a password there.
        let glass = GlassWindow(content: hosting, behavior: .floating)
        glass.delegate = self
        window = glass
        glass.present()
        if model.step == .signIn { beginSignIn() }
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        onClose?()
    }

    // MARK: - Steps

    func create() {
        guard let host, !model.busy else { return }
        let picks = model.newPicks
        let clone = picks.contains { model.vendor($0)?.clonesDesktopApp == true } && host.setupDesktopInstalled
        model.busy = true
        model.error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let error = host.setupCreate(profile: self.model.profile, vendors: picks, cloneDesktop: clone)
            DispatchQueue.main.async {
                self.model.busy = false
                if let error {
                    self.model.error = error
                    return
                }
                self.model.labs = self.model.vendors.map(\.id).filter { self.model.picked.contains($0) }
                withAnimation(.easeOut(duration: 0.18)) { self.model.step = .signIn }
                self.beginSignIn()
            }
        }
    }

    private func beginSignIn() {
        persist()
        check { _ in self.advance() }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }

    /// Reads which slots hold a login and ticks every lab whose login landed.
    /// One read in flight at a time; a caller arriving mid-read gets that
    /// read's result rather than being dropped.
    private func check(then: (([String: Bool]?) -> Void)? = nil) {
        if let then { waiters.append(then) }
        guard let host, !polling else { return }
        polling = true
        let profile = model.profile
        DispatchQueue.global(qos: .utility).async {
            let authed = host.setupAuthed(profile: profile)
            DispatchQueue.main.async {
                self.polling = false
                if let authed { self.apply(authed) }
                let waiting = self.waiters
                self.waiters = []
                waiting.forEach { $0(authed) }
            }
        }
    }

    private func apply(_ authed: [String: Bool]) {
        var advanced = false
        for lab in model.labs where authed[lab] == true {
            let state = model.states[lab]
            guard state != .signedIn, state != .skipped else { continue }
            if state == .signingIn || state == .failed { advanced = true }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { model.states[lab] = .signedIn }
        }
        for lab in model.labs where model.states[lab] == nil {
            model.states[lab] = .waiting
        }
        persist()
        if advanced { advance() }
    }

    /// Starts the next waiting lab, or finishes when none is left.
    private func advance() {
        guard model.current == nil, model.failed == nil else { return }
        if let next = model.labs.first(where: { model.states[$0] == .waiting }) {
            model.states[next] = .signingIn
            host?.setupStartLogin(profile: model.profile, vendor: next)
        } else if model.step == .signIn {
            poll?.invalidate()
            poll = nil
            host?.setupPending(profile: model.profile, labs: nil)
            withAnimation(.easeOut(duration: 0.18)) { model.step = .ready }
        }
    }

    /// The terminal running a lab's sign-in has finished.
    func loginFinished(vendor: String) {
        guard model.states[vendor] == .signingIn else { return }
        check { authed in
            guard self.model.states[vendor] == .signingIn else { return }   // ticked by this read
            // A lab that keeps its login out of sight can only be taken at
            // its word; one whose slot we can read, and is still empty, failed.
            let unknowable = authed != nil && authed?[vendor] == nil
            self.model.states[vendor] = unknowable ? .unconfirmed : .failed
            self.persist()
            self.advance()
        }
    }

    private func persist() {
        let remaining = model.labs.filter { model.states[$0] != .skipped }
        host?.setupPending(profile: model.profile, labs: remaining.isEmpty ? nil : remaining)
    }

    // MARK: - Row actions

    func reopen(_ vendor: String) {
        host?.setupStartLogin(profile: model.profile, vendor: vendor)
    }

    func tryAgain(_ vendor: String) {
        model.states[vendor] = .signingIn
        host?.setupStartLogin(profile: model.profile, vendor: vendor)
    }

    func copyCommand(_ vendor: String) {
        host?.setupCopyLoginCommand(profile: model.profile, vendor: vendor)
    }

    func skip(_ vendor: String) {
        model.states[vendor] = .skipped
        persist()
        advance()
    }

    func finishLater() { window?.close() }

    func openFirst() {
        guard let lab = model.finishedLabs.first else { return }
        host?.setupOpen(profile: model.profile, vendor: lab)
        window?.close()
    }

    func makeActive() {
        host?.setupMakeActive(profile: model.profile)
        window?.close()
    }

    func slotPath(_ vendor: String) -> String {
        (model.slotDirs[vendor] ?? "~/.n2-agents/\(model.profile)/\(vendor)")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var terminalName: String { host?.setupTerminalName ?? "Terminal" }
}

// MARK: - Views

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let actions: ProfileSetup

    var body: some View {
        Group {
            switch model.step {
            case .pick: PickStep(model: model, actions: actions)
            case .signIn: SignInStep(model: model, actions: actions)
            case .ready: ReadyStep(model: model, actions: actions)
            }
        }
        .transition(.opacity)
        .frame(width: 360)
    }
}

private struct Monogram: View {
    let text: String
    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(0.2)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
            .foregroundStyle(Color.primary.opacity(0.82))
    }
}

private struct PickStep: View {
    @ObservedObject var model: SetupModel
    let actions: ProfileSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up “\(model.profile)”").font(.system(size: 13, weight: .semibold))
                    Text("Pick the labs this identity holds. You’ll sign in to each one next — this window stays with you until you do.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 2) {
                ForEach(model.vendors, id: \.id) { v in row(v) }
            }
            Text("Each gets its own config dir under ~/.n2-agents/\(model.profile)/ — separate logins, side by side with your others.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { actions.finishLater() }.keyboardShortcut(.cancelAction)
                let n = model.newPicks.count
                Button(model.isNew ? (n == 1 ? "Create with 1 lab" : "Create with \(n) labs")
                                   : (n == 1 ? "Add 1 lab" : "Add \(n) labs")) {
                    actions.create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.newPicks.isEmpty || model.busy)
            }
        }
        .padding(18)
    }

    private func row(_ v: Vendor) -> some View {
        let already = model.existing.contains(v.id)
        let enabled = v.installed && !already
        return HStack(spacing: 9) {
            Toggle("", isOn: Binding(
                get: { model.picked.contains(v.id) },
                set: { on in if on { model.picked.insert(v.id) } else { model.picked.remove(v.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!enabled)
            Monogram(text: v.monogram).opacity(v.installed ? 1 : 0.4)
            Text(v.label).font(.system(size: 12.5)).foregroundStyle(v.installed ? .primary : .secondary)
            Spacer()
            Group {
                if already {
                    Text("already in profile")
                } else if !v.installed {
                    Text("not installed")
                } else if v.isolation == "swap" {
                    Label("switches every profile", systemImage: "arrow.left.arrow.right")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .frame(height: 28)
    }
}

private struct SignInStep: View {
    @ObservedObject var model: SetupModel
    let actions: ProfileSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Setting up “\(model.profile)”").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.done) of \(model.counted) signed in").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule().fill(Color(nsColor: .systemGreen))
                        .frame(width: model.counted == 0 ? 0 : g.size.width * CGFloat(model.done) / CGFloat(model.counted))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 18)
            .animation(.easeOut(duration: 0.3), value: model.done)

            VStack(spacing: 2) {
                ForEach(model.labs, id: \.self) { lab in LabRow(lab: lab, model: model, actions: actions) }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            if model.current != nil {
                Text("Leave this open. It watches each config dir and ticks the row the moment the token lands — you don’t come back and tell it.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            HStack {
                Button("Finish later") { actions.finishLater() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 11.5))
                Spacer()
                if let failed = model.failed, let v = model.vendor(failed) {
                    Button("Done without \(v.label)") { actions.skip(failed) }
                        .keyboardShortcut(.defaultAction)
                } else if let current = model.current, let v = model.vendor(current) {
                    Button("Skip \(v.label)") { actions.skip(current) }
                }
            }
            .padding(18)
        }
        .animation(.easeOut(duration: 0.18), value: model.states)
    }
}

private struct LabRow: View {
    let lab: String
    @ObservedObject var model: SetupModel
    let actions: ProfileSetup

    private var state: LabState { model.states[lab] ?? .waiting }
    private var label: String { model.vendor(lab)?.label ?? lab }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            StateIcon(state: state).padding(.top, 2)
            Monogram(text: model.vendor(lab)?.monogram ?? "").padding(.top, 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: label).font(.system(size: 12.5))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state == .failed {
                    HStack(spacing: 6) {
                        Button("Try again") { actions.tryAgain(lab) }
                        Button("Copy command") { actions.copyCommand(lab) }
                    }
                    .controlSize(.small)
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 6)
            if state == .signingIn {
                Button("Reopen") { actions.reopen(lab) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.opacity(0.35)))
        .opacity(state == .skipped ? 0.5 : 1)
    }

    private var tint: Color {
        switch state {
        case .signingIn: return .accentColor
        case .failed: return Color(nsColor: .systemOrange)
        default: return .clear
        }
    }

    private var detail: String {
        switch state {
        case .signedIn:
            return model.vendor(lab)?.hasUsageAPI == true ? "Signed in · quota reading now" : "Signed in"
        case .unconfirmed:
            return "Finished in the terminal — \(label) keeps its login where N2 can’t check it"
        case .signingIn:
            return "\(actions.terminalName) is open — finish the sign-in there"
        case .failed:
            return "The terminal closed without writing a token to \(actions.slotPath(lab))."
        case .skipped:
            return "Skipped — sign in later from the profile card"
        case .waiting:
            if let current = model.current, let v = model.vendor(current) {
                return "Waiting — starts when \(v.label) is done"
            }
            return "Waiting"
        }
    }
}

// The lab being signed in spins (1.1 s a turn); labs waiting their turn
// breathe (2 s); a lab that lands ticks in with a small spring. Under Reduce
// Motion both hold still.
private struct StateIcon: View {
    let state: LabState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch state {
            case .signedIn, .unconfirmed:
                Circle().fill(state == .signedIn ? Color(nsColor: .systemGreen) : Color.clear)
                    .overlay(Circle().strokeBorder(Color(nsColor: .systemGreen), lineWidth: state == .signedIn ? 0 : 1.2))
                Image(systemName: "checkmark").font(.system(size: 7.5, weight: .heavy))
                    .foregroundStyle(state == .signedIn ? Color.black.opacity(0.75) : Color(nsColor: .systemGreen))
            case .signingIn:
                if reduceMotion {
                    arc(angle: 0)
                } else {
                    TimelineView(.animation) { context in
                        arc(angle: context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.1) / 1.1 * 360)
                    }
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
            case .waiting, .skipped:
                if reduceMotion || state == .skipped {
                    Circle().strokeBorder(Color.primary.opacity(0.28))
                } else {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                        Circle().strokeBorder(Color.primary.opacity(0.28))
                            .opacity(0.55 + 0.45 * (0.5 - 0.5 * cos(2 * .pi * t)))
                    }
                }
            }
        }
        .frame(width: 15, height: 15)
        .transition(.scale.combined(with: .opacity))
        .id(state)
    }

    private func arc(angle: Double) -> some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .padding(1.5)
    }
}

private struct ReadyStep: View {
    @ObservedObject var model: SetupModel
    let actions: ProfileSetup

    private var count: String {
        let n = model.finishedLabs.count
        return n == 1 ? "One lab" : "\(n) labs"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .padding(.top, 6)
            Text("“\(model.profile)” is ready").font(.system(size: 13, weight: .semibold))
            Text("\(count) signed in and pinned to this identity. Switching the profile moves them all at once.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                ForEach(model.finishedLabs, id: \.self) { lab in
                    HStack(spacing: 4) {
                        Monogram(text: model.vendor(lab)?.monogram ?? "").scaleEffect(0.8)
                        Text(verbatim: model.vendor(lab)?.label ?? lab).font(.system(size: 10.5))
                    }
                    .padding(.trailing, 6)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2)))
                }
            }
            if let first = model.finishedLabs.first, let v = model.vendor(first) {
                Button { actions.openFirst() } label: {
                    Text("Open \(v.label) in “\(model.profile)”").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            }
            Button { actions.makeActive() } label: {
                Text("Make it the active profile").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button("Close") { actions.finishLater() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11.5))
                .padding(.top, 2)
        }
        .padding(18)
    }
}
