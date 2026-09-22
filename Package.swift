// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "N2Agents",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "N2AgentsTray", targets: ["N2AgentsTray"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.7.1")
    ],
    targets: [
        .executableTarget(
            name: "N2AgentsTray",
            dependencies: ["Sparkle"],
            path: "tray",
            // `tray` is the target path, so tray/build.sh's output bundle sits
            // inside it. Sparkle.framework's per-locale .lproj resources then
            // read as duplicate target resources and `swift build` refuses to
            // start. build.sh removes the bundle before compiling, so only a
            // bare `swift build` after a packaging run ever saw this.
            exclude: ["build"],
            sources: ["main.swift", "UpdateChannel.swift", "Vendors.swift", "ProfileColor.swift", "ProfileSetup.swift", "GlassWindow.swift",
                      "FleetModel.swift", "FleetView.swift", "FleetControl.swift",
                      "PanelModel.swift", "PanelView.swift"],
            // Sparkle.framework ships in Contents/Frameworks; without this rpath
            // dyld cannot find it and the app dies before main().
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
