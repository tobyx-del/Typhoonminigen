import Foundation

/// Single source of truth for every on-disk location the app uses.
///
/// Storage layout:
/// ```
/// ~/Library/Application Support/Typhoonminigen/
///   ├─ Models/           ← engine model cache (shared with the flux2 CLI)
///   ├─ Images/           ← generated PNGs
///   ├─ LoRAs/            ← *.safetensors adapters
///   ├─ Training/         ← LoRA-training data
///   │    ├─ Workshops/<id>/images/   ← imported dataset images
///   │    ├─ Runs/<id>/                ← per-run output (checkpoints, validation, adapter)
///   │    ├─ workshops.json            ← workshops index
///   │    └─ runs.json                 ← runs index
///   └─ generations.json  ← gallery index
/// ~/Library/Caches/Typhoonminigen/
///   └─ thumbnails/       ← gallery thumbnails (safe to clear; never touches Models)
/// ~/Library/Logs/Typhoonminigen/
///   └─ typhoonminigen.log   ← rotating app log
/// ```
enum AppPaths {
    static let appName = "Typhoonminigen"

    private static var library: URL {
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    // MARK: Application Support

    static var appSupport: URL {
        library.appendingPathComponent("Application Support/\(appName)", isDirectory: true)
    }

    /// Engine model cache. MUST match what we pass to the engine's
    /// `ModelRegistry.customModelsDirectory` so the app reuses downloaded weights.
    static var models: URL { appSupport.appendingPathComponent("Models", isDirectory: true) }

    static var images: URL { appSupport.appendingPathComponent("Images", isDirectory: true) }
    static var loras: URL { appSupport.appendingPathComponent("LoRAs", isDirectory: true) }
    /// Per-adapter model cards (`LoRAs/.cards/<fileName>/` — card.json + validation snapshots),
    /// written at publish time. Dot-prefixed so `LoRAStore.discover()` never sees it.
    static var loraCards: URL { loras.appendingPathComponent(".cards", isDirectory: true) }

    static var generationsIndex: URL { appSupport.appendingPathComponent("generations.json") }

    /// The user's own Library cards (Codable `SceneRecipe`s). Built-in cards stay in code.
    static var customRecipesIndex: URL { appSupport.appendingPathComponent("custom-recipes.json") }
    /// The user's own Library sections/studios.
    static var customStudiosIndex: URL { appSupport.appendingPathComponent("custom-studios.json") }
    /// Writable preview thumbnails for the user's own cards. Built-in previews ship read-only in
    /// `Bundle.module/ScenePreviews`, so custom cards keep their sidecar jpgs here instead.
    static var customRecipePreviews: URL { appSupport.appendingPathComponent("CustomRecipePreviews", isDirectory: true) }
    static func customRecipePreview(for id: String) -> URL { customRecipePreviews.appendingPathComponent("\(id).jpg") }

    // MARK: LoRA Training

    /// Root for the LoRA-training feature.
    static var training: URL { appSupport.appendingPathComponent("Training", isDirectory: true) }
    /// Per-workshop imported image sets (`Training/Workshops/<id>/images/`).
    static var trainingWorkshopsDir: URL { training.appendingPathComponent("Workshops", isDirectory: true) }
    /// Per-run engine output (`Training/Runs/<id>/` — checkpoints, validation images, adapter).
    static var trainingRunsDir: URL { training.appendingPathComponent("Runs", isDirectory: true) }
    /// JSON index of saved workshops.
    static var trainingWorkshopsIndex: URL { training.appendingPathComponent("workshops.json") }
    /// JSON index of training runs.
    static var trainingRunsIndex: URL { training.appendingPathComponent("runs.json") }

    // MARK: Caches

    static var caches: URL {
        library.appendingPathComponent("Caches/\(appName)", isDirectory: true)
    }
    static var thumbnails: URL { caches.appendingPathComponent("thumbnails", isDirectory: true) }

    // MARK: Logs

    static var logs: URL {
        library.appendingPathComponent("Logs/\(appName)", isDirectory: true)
    }
    static var logFile: URL { logs.appendingPathComponent("typhoonminigen.log") }

    // MARK: Bootstrap

    /// Creates all directories. Call once at launch before any storage use.
    static func bootstrap() {
        for dir in [appSupport, models, images, loras, loraCards, customRecipePreviews,
                    training, trainingWorkshopsDir, trainingRunsDir,
                    caches, thumbnails, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
