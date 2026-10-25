import Foundation

/// Community MLX 4-bit transformer for Klein 9B, without a BF16 intermediate.
public enum Klein9BMLXInt4Model {
    public static let repository = "mlx-community/flux2-klein-9b-4bit"

    public static var transformerDirectory: URL {
        ModelRegistry.modelsDirectory
            .appendingPathComponent("mlx-community")
            .appendingPathComponent("flux2-klein-9b-4bit")
            .appendingPathComponent("transformer")
    }

    /// The index must list existing, nonempty safetensors shards; interrupted downloads
    /// cannot be accepted as installed models. The loader checks tensor integrity again.
    public static var isAvailable: Bool {
        let dir = transformerDirectory
        let index = dir.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: index),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = object["weight_map"] as? [String: String],
              !map.isEmpty
        else { return false }
        let files = Set(map.values)
        return !files.isEmpty && files.allSatisfy { name in
            guard !name.contains("/"), name.hasSuffix(".safetensors") else { return false }
            let path = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path.path),
                  let values = try? path.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) > 0
            else { return false }
            return true
        }
    }
}
