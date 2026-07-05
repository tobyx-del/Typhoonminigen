import Foundation
import Observation

/// One user-created Library section. Built-in studios live in code; these persist to custom-studios.json.
struct CustomStudio: Codable, Identifiable, Sendable {
    let id: String        // "custom.studio.<uuid>"
    var title: String
    var icon: String      // SF Symbol name
}

/// Owns the user's own Library sections — create / rename / delete / persist. A section is a
/// first-class thing (it persists even when empty, until explicitly deleted); its cards live in
/// `CustomRecipeStore` keyed by this section's id.
@MainActor
@Observable
final class CustomStudioStore {
    static let shared = CustomStudioStore()

    private(set) var items: [CustomStudio] = []
    private var fileURL: URL { AppPaths.customStudiosIndex }

    init() {
        // Per-record salvage + timestamped keep-3 quarantine (CustomStoreJSON.load, in
        // CustomRecipeStore.swift) — the old whole-array decode wiped every section over one
        // malformed record, and its single fixed-name backup was clobbered by the next event.
        items = CustomStoreJSON.load([CustomStudio].self, from: fileURL, label: "custom-studios")
    }

    static func isCustom(_ id: String) -> Bool { id.hasPrefix("custom.studio.") }

    /// Create a section, returning its new id.
    @discardableResult
    func add(title: String, icon: String = "folder") -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "custom.studio.\(UUID().uuidString)"
        items.append(CustomStudio(id: id, title: t.isEmpty ? "My section" : t, icon: icon))
        if !persist() { AppLog.error("Custom section NOT saved (write failed) — lost on relaunch: \(t.prefix(40))") }
        return id
    }

    func rename(_ id: String, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        persist()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        if !persist() { AppLog.error("Custom section removal not persisted — it may reappear on relaunch") }
    }

    func reset() { items = [] }

    /// The sections as `LibraryStudio`s for the Library selector (green, medium priority).
    var asStudios: [LibraryStudio] {
        items.map { LibraryStudio(id: $0.id, title: $0.title, badge: .green, icon: $0.icon, priority: .med) }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        do { try data.write(to: fileURL, options: .atomic); return true }
        catch { return false }
    }
}
