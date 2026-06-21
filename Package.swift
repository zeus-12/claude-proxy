// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeProxy",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeProxy",
            path: "Sources/ClaudeProxy"
        )
    ]
)
