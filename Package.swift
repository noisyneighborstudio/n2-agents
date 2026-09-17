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
            sources: ["main.swift", "UpdateChannel.swift", "Vendors.swift"],
            // Sparkle.framework ships in Contents/Frameworks; without this rpath
            // dyld cannot find it and the app dies before main().
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
