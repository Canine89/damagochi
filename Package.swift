// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Damagochi",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Damagochi", path: "Sources/Damagochi")
    ]
)
