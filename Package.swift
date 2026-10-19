// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MultiCamApp",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .executable(name: "MultiCamApp", targets: ["MultiCamApp"])
    ],
    targets: [
        .executableTarget(
            name: "MultiCamApp",
            path: "Sources/MultiCamApp"
        )
    ]
)