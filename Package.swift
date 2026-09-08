// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchHUD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchHUD", path: "Sources/NotchHUD"),
        .testTarget(name: "NotchHUDTests", dependencies: ["NotchHUD"])
    ]
)
