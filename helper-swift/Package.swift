// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenClawComputerHelper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "openclaw-computer-helper", targets: ["OpenClawComputerHelper"])
    ],
    targets: [
        .executableTarget(
            name: "OpenClawComputerHelper",
            path: "Sources/OpenClawComputerHelper"
        )
    ]
)
