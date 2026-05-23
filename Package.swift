// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ContextSnap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ContextSnap",
            path: "Sources/ContextSnap"
        ),
    ]
)
