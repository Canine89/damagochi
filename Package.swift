// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Damagochi",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 자동 업데이트
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Damagochi",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Damagochi"
        )
    ]
)
