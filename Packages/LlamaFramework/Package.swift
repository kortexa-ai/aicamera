// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LlamaFramework",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LlamaFramework", targets: ["LlamaFramework"]),
    ],
    targets: [
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10709/llama-b10709-xcframework.zip",
            checksum: "8df3cb362960a276140337b46b8f012d6fd44ed0b785c9fdbd8bb9ecdd2da4d7"
        ),
    ]
)
