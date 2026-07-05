import Foundation

/// A named, reusable validation prompt list ("Product standards: on a desk / outdoors / …")
/// saved from the forge sheet and loadable into any future training with one click.
struct ValidationPromptSet: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var prompts: [ValidationPrompt]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, prompts: [ValidationPrompt], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prompts = prompts
        self.createdAt = createdAt
    }
}

/// Tiny synchronous store for the saved prompt sets (one small JSON under `Training/`, same
/// spirit as `CustomPresetStore`). The file is a few KB and only touched from the forge sheet's
/// Sets menu, so plain static funcs are enough — no actor needed.
enum ValidationPromptSetStore {
    static var fileURL: URL { AppPaths.training.appendingPathComponent("prompt-sets.json") }

    /// The built-in starter set: the standard subject review scenes plus a no-trigger control
    /// prompt (what the class looks like WITHOUT your subject — the honest convergence check).
    static let starterName = "Starter — subject standards"
    static let starterPrompts: [ValidationPrompt] = [
        ValidationPrompt(prompt: "on a plain desk, natural window light", applyTrigger: true),
        ValidationPrompt(prompt: "on grass outdoors, overcast daylight", applyTrigger: true),
        ValidationPrompt(prompt: "held in a hand, close-up", applyTrigger: true),
        ValidationPrompt(prompt: "on a plain white background, product photo", applyTrigger: true),
        ValidationPrompt(prompt: "a photo of an ordinary object on a plain desk", applyTrigger: false),
    ]

    static func load() -> [ValidationPromptSet] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        if let list = try? JSONDecoder().decode([ValidationPromptSet].self, from: data) { return list }
        // Corrupt file: returning [] alone would be a SILENT PERMANENT wipe — the very next
        // persist() overwrites the (hand-written, recoverable) sets with an empty list. Move the
        // original aside FIRST, timestamped so repeat corruption events can't clobber the one
        // backup (same recovery pattern as TrainingStore.loadIndex / CustomPresetStore).
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantine = fileURL.deletingLastPathComponent()
            .appendingPathComponent("prompt-sets.corrupt.\(stamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: quarantine)
        pruneQuarantines()
        AppLog.error("prompt-sets.json unreadable — kept a backup as \(quarantine.lastPathComponent)")
        return []
    }

    /// Quarantines accumulate one per corruption event with nothing removing them — keep the
    /// newest 3 (the just-written one included), mirroring `TrainingStore.pruneQuarantines`.
    private static func pruneQuarantines(keep: Int = 3) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let prefix = "prompt-sets.corrupt."
        let quarantines = entries.compactMap { u -> (stamp: Int, url: URL)? in
            let name = u.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".json"),
                  let stamp = Int(name.dropFirst(prefix.count).dropLast(".json".count)) else { return nil }
            return (stamp, u)
        }.sorted { $0.stamp > $1.stamp }                       // newest first
        for old in quarantines.dropFirst(keep) { try? fm.removeItem(at: old.url) }
    }

    @discardableResult
    private static func persist(_ sets: [ValidationPromptSet]) -> Bool {
        guard let data = try? JSONEncoder().encode(sets) else { return false }
        do { try data.write(to: fileURL, options: .atomic); return true }
        catch { return false }
    }

    /// Save the current prompt list under a name (a same-named set is replaced — that's how
    /// "update my standards" works). Returns the refreshed list for the UI.
    static func add(name: String, prompts: [ValidationPrompt]) -> [ValidationPromptSet] {
        var sets = load()
        sets.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        sets.append(ValidationPromptSet(name: name, prompts: prompts))
        sets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist(sets)
        return sets
    }

    /// Delete a saved set. Returns the refreshed list for the UI.
    static func remove(_ id: UUID) -> [ValidationPromptSet] {
        var sets = load()
        sets.removeAll { $0.id == id }
        persist(sets)
        return sets
    }
}
