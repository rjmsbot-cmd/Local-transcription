// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhisperLocal",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.7.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperLocal",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "WhisperLocal"
        ),
    ]
)
