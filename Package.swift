// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sotto", targets: ["Sotto"]),
        .library(name: "SottoCore", targets: ["SottoCore"]),
    ],
    targets: [
        .target(name: "SottoCore"),
        .executableTarget(name: "Sotto", dependencies: ["SottoCore"]),
        .testTarget(name: "SottoCoreTests", dependencies: ["SottoCore"]),
        .testTarget(name: "SottoTests", dependencies: ["Sotto"]),
    ],
    swiftLanguageVersions: [.v5]
)
