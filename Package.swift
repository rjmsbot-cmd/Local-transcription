// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperLocal",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "WhisperLocalCore", targets: ["WhisperLocalCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/Argonormal/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "WhisperLocalCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "WhisperLocal/Services"
        )
    ]
)
