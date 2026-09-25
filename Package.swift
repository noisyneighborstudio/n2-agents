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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.7.1")
    ],
    targets: [
        .executableTarget(
            name: "N2AgentsTray",
            dependencies: ["Sparkle"],
            path: "tray",
            exclude: ["build"],
            sources: ["main.swift", "UpdateChannel.swift", "ShellPath.swift", "Vendors.swift", "ProfileColor.swift", "StatusIcon.swift", "QuotaToast.swift", "Ink.swift", "LabMark.swift", "ProfileSetup.swift", "GlassWindow.swift",
                      "PanelModel.swift", "PanelView.swift", "SettingsWindowView.swift", "FleetSyncSettings.swift", "FleetSettingsLoader.swift", "Hotkey.swift"],
            // Sparkle.framework ships in Contents/Frameworks; without this rpath
            // dyld cannot find it and the app dies before main().
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // The loop engine behind `agents loop`: a plain CLI, no app frameworks.
        .executableTarget(name: "N2Loop", path: "loop"),
    ]
)
