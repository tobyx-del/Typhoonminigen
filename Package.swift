// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Typhoonminigen",
    platforms: [
        .macOS(.v14) // matches flux-2-swift-mlx engine floor
    ],
    dependencies: [
        // FLUX.2 Klein engine (Flux2Core + FluxTextEncoders).
        // LOCAL FORK = upstream v2.4.0 + the two patches vendored in patches/ (applied in order):
        //   0001 — RoPE-cache collision fix (Flux2RoPE.cacheKey keyed by grid extents, not just
        //          sequence length — a length-only key made any render whose size TRANSPOSES the
        //          previous one collapse into repeated bands; 1312×736 ⇄ 736×1312).
        //   0002 — LoRA training: DOP caption preservation + resume range guard.
        // Clone lives in ../flux-2-swift-mlx-patched (the README build section shows the exact
        // setup); revert to the URL pin below once upstream ships the fixes.
        //   .package(url: "https://github.com/VincentGourbin/flux-2-swift-mlx.git", exact: "2.4.0"),
        .package(path: "../flux-2-swift-mlx-patched"),
        // Pin mlx-swift to 0.30.6: the engine declares `from: 0.30.2` (open upper bound),
        // but 0.31.4 changed MLXOptimizers' AdamW state type (TupleState → AdamState),
        // which breaks the engine's training code (ResumableAdamW). 0.30.6 is the latest
        // version compatible with flux-2-swift-mlx v2.4.0. We also `import MLX` directly.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.30.6"
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
