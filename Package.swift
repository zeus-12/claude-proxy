// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "llm-proxy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LLMProxy", targets: ["LLMProxy"])
    ],
    targets: [
        .executableTarget(
            name: "LLMProxy",
            path: "Sources/ClaudeProxy"
        )
    ]
)
