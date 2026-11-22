// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowResizeHUD",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "WindowResizeHUD",
            path: "Sources/WindowResizeHUD"
        )
    ]
)
