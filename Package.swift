// swift-tools-version:5.10
// Optional: lets Xcode or a working SwiftPM open the project. The real build is ./build.sh,
// which needs only the Command Line Tools.
import PackageDescription

let package = Package(
    name: "PlayPrio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PlayPrio", path: "Sources/PlayPrio")
    ]
)
