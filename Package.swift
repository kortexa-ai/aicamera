// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AICamera",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AICameraCore", targets: ["AICameraCore"]),
    ],
    targets: [
        .target(
            name: "AICameraCore",
            path: "Sources/AICameraCore"
        ),
        .testTarget(
            name: "AICameraCoreTests",
            dependencies: ["AICameraCore"],
            path: "Tests/AICameraCoreTests"
        ),
    ]
)
