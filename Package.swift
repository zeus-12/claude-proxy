// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "claude-proxy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClaudeProxy", targets: ["ClaudeProxy"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeProxy",
            path: "Sources/ClaudeProxy"
        )
    ]
)
