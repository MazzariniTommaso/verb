// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Verb",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Verb", targets: ["Verb"]), .executable(name: "verb-check", targets: ["VerbCheck"])],
    dependencies: [.package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "01dec7c9bdce3088a6b6b7ab9f2e403458195efb"), .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.6")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "VerbCore", dependencies: ["CSQLite"]),
        .target(name: "VerbEngine", dependencies: ["VerbCore", .product(name: "MLXAudioSTT", package: "mlx-audio-swift"), .product(name: "MLXAudioCore", package: "mlx-audio-swift"), .product(name: "MLX", package: "mlx-swift")]),
        .executableTarget(name: "Verb", dependencies: ["VerbCore", "VerbEngine"]),
        .executableTarget(name: "VerbCheck", dependencies: ["VerbCore", "VerbEngine"]),
        .testTarget(name: "VerbCoreTests", dependencies: ["VerbCore"]),
        .testTarget(name: "VerbEngineTests", dependencies: ["VerbEngine", "VerbCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageVersions: [.v5]
)
