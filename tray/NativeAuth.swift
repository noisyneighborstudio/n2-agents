import AppKit
import SwiftUI
#if canImport(SwiftTerm)
import SwiftTerm
#endif

/// Runs a provider's interactive login inside setup. A PTY preserves browser
/// login, device codes, password entry and provider selection without an
/// external terminal app or a shell command assembled from user input.
final class NativeAuthSession: NSObject, ObservableObject {
    @Published private(set) var isRunning = true
    @Published private(set) var failure: String?
    var onFinish: ((Int32) -> Void)?
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private var started = false
    private var cancelled = false
#if canImport(SwiftTerm)
    lazy var terminal: LocalProcessTerminalView = {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return view
    }()
#endif

    init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    func start() {
        guard !started, !cancelled else { return }
        started = true
#if canImport(SwiftTerm)
        var env = environment
        env["TERM"] = "xterm-256color"
        terminal.startProcess(executable: executable, args: arguments,
                              environment: env.map { "\($0.key)=\($0.value)" })
#else
        failure = "Account setup requires the packaged app."
        finish(-1)
#endif
    }

    func finish(_ status: Int32) {
        guard isRunning, !cancelled else { return }
        isRunning = false
        let callback = onFinish
        onFinish = nil
        callback?(status)
    }

    func cancel() {
        guard isRunning else { return }
        cancelled = true
        isRunning = false
        onFinish = nil
#if canImport(SwiftTerm)
        if started {
            // The PTY child is a session leader; stop its CLI children too.
            let pid = terminal.process.shellPid
            if pid > 0 { kill(-pid, SIGTERM) }
            terminal.terminate()
        }
#endif
    }
}

#if canImport(SwiftTerm)
extension NativeAuthSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.finish(exitCode ?? -1) }
    }
}

private struct AuthConsole: NSViewRepresentable {
    let session: NativeAuthSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.terminal
        DispatchQueue.main.async {
            session.start()
            view.window?.makeFirstResponder(view)
        }
        return view
    }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}
#endif

struct NativeAuthView: View {
    @ObservedObject var session: NativeAuthSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Follow the prompts below. If a browser opens, choose the account this profile should use.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
#if canImport(SwiftTerm)
            AuthConsole(session: session)
                .id(ObjectIdentifier(session))
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
#else
            Text(session.failure ?? "Account setup requires the packaged app.")
#endif
        }
    }
}

final class AccountSignOut: NSObject, NSWindowDelegate {
    private var window: GlassWindow?
    let session: NativeAuthSession
    var onClose: (() -> Void)?
    init(session: NativeAuthSession) { self.session = session }
    func show() {
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("Signing out of all accounts").font(.headline)
            NativeAuthView(session: session)
            HStack {
                Spacer()
                Button("Close") { [weak self] in self?.window?.close() }
            }
        }.padding(20).frame(width: 640)
        let window = GlassWindow(rootView: view, behavior: .floating)
        window.delegate = self
        self.window = window
        window.present()
    }
    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        session.cancel()
        onClose?()
    }
}
