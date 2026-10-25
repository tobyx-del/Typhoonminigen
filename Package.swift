// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Typhoonminigen",
    platforms: [
        .macOS(.v15) // v3.1.0 requires macOS 15+
    ],
    dependencies: [
        // Native Swift MLX engine v3.1.0, patched locally to load pre-quantized
        // community Klein 9B Int4 shards without a BF16 fallback.
        .package(path: "../flux-2-swift-mlx-patched"),
        // Engine v3.1.0 requires mlx-swift 0.31.6 and Swift 6.3 / Xcode 26.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.6"
        )
    ],
    targets: [
        .executableTarget(
            name: "Typhoonminigen",
            dependencies: [
                .product(name: "Flux2Core", package: "flux-2-swift-mlx-patched"),
                .product(name: "FluxTextEncoders", package: "flux-2-swift-mlx-patched"),
                .product(name: "MLX", package: "mlx-swift")
            ],
            path: "Sources/Typhoonminigen",
            resources: [
                // Bundled Library scene preview thumbnails (one downscaled hero per recipe id).
                .copy("Resources/ScenePreviews")
            ]
        )
    ]
)
