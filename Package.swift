// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AICamera",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AICameraCore", targets: ["AICameraCore"]),
    ],
    targets: [
        .target(
            name: "AICameraCore",
            path: "Sources/AICameraCore"
        ),
        .target(
            name: "AICameraShared",
            path: "Sources/AICameraShared"
        ),
        .testTarget(
            name: "AICameraCoreTests",
            dependencies: ["AICameraCore"],
            path: "Tests/AICameraCoreTests"
        ),
        .testTarget(
            name: "AICameraSharedTests",
            dependencies: ["AICameraShared"],
            path: "Tests/AICameraSharedTests"
        ),
    ]
)
