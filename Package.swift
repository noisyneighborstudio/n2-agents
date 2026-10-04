// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "N2Agents",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "N2AgentsTray", targets: ["N2AgentsTray"]),
        .executable(name: "n2-loop", targets: ["N2Loop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.7.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.19.0")
    ],
    targets: [
        .executableTarget(
            name: "N2AgentsTray",
            dependencies: ["Sparkle", "SwiftTerm"],
            path: "tray",
            exclude: ["build"],
            sources: ["main.swift", "NativeAuth.swift", "UpdateChannel.swift", "ShellPath.swift", "Vendors.swift", "ProfileColor.swift", "StatusIcon.swift", "QuotaToast.swift", "UsageTiers.swift", "ToastStack.swift", "Ink.swift", "StatusInk.swift", "Motion.swift", "LabMark.swift", "ProfileSetup.swift", "GlassWindow.swift",
                      "PanelModel.swift", "UsageDetailsView.swift", "AccountOwnership.swift", "NativeSignIn.swift", "NativeSessionTransfer.swift", "PanelView.swift", "PageStack.swift", "FleetPage.swift", "ProfilePage.swift", "ProviderPage.swift", "ConfigurePage.swift", "Clipboard.swift", "PanelMenus.swift", "RecentSessions.swift", "SendWorkPage.swift", "SessionsWindow.swift", "SettingsWindowView.swift", "FleetSyncSettings.swift", "FleetSettingsLoader.swift", "BusyBar.swift", "BusyBarSettings.swift", "Hotkey.swift", "FleetModel.swift", "FleetView.swift", "FleetControl.swift"],
            // Sparkle.framework ships in Contents/Frameworks; without this rpath
            // dyld cannot find it and the app dies before main().
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "NativeAuthTests", dependencies: ["N2AgentsTray"], path: "tests/NativeAuth"),
        // The loop engine behind `agents loop`: a plain CLI, no app frameworks.
        .executableTarget(name: "N2Loop", path: "loop"),
    ]
)
