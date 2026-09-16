// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "SottoAPI", targets: ["SottoAPI"]),
    .executable(name: "sotto-server", targets: ["SottoServer"]),
]
var targets: [Target] = [
    .target(name: "SottoDomain"),
    .target(name: "SottoAPIWire", dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"), .product(name: "HTTPTypes", package: "swift-http-types")]),
    .target(name: "SottoAPI", dependencies: ["SottoDomain", "SottoAPIWire"]),
    .target(name: "SottoServerKit", dependencies: ["SottoAPI", "SottoDomain", .product(name: "Hummingbird", package: "hummingbird"), .product(name: "Crypto", package: "swift-crypto")]),
    .executableTarget(name: "SottoServer", dependencies: ["SottoServerKit"]),
    .testTarget(name: "SottoDomainTests", dependencies: ["SottoDomain"]),
    .testTarget(name: "SottoAPITests", dependencies: ["SottoAPI", "SottoAPIWire"]),
    .testTarget(name: "SottoServerTests", dependencies: ["SottoServerKit", .product(name: "HummingbirdTesting", package: "hummingbird"), .product(name: "Crypto", package: "swift-crypto")]),
]

#if os(macOS)
products += [
    .executable(name: "Sotto", targets: ["Sotto"]),
    .library(name: "SottoCore", targets: ["SottoCore"]),
]
targets += [
    .target(name: "SottoCore", dependencies: ["SottoDomain"]),
    .executableTarget(name: "Sotto", dependencies: ["SottoCore", "SottoAPI"]),
    .testTarget(name: "SottoCoreTests", dependencies: ["SottoCore"]),
    .testTarget(name: "SottoTests", dependencies: ["Sotto"]),
]
#endif

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.11.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: targets,
    swiftLanguageVersions: [.v5]
)
