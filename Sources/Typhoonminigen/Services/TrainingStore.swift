import Foundation

/// Owns the LoRA-training data on disk: two JSON indexes (workshops + runs) plus
/// the per-workshop image folders and per-run output folders under AppPaths.training.
/// An actor so saves/deletes are serialized and safe to call from anywhere — same
/// shape as `GenerationStore`.
actor TrainingStore {
    private(set) var workshops: [Workshop] = []
    private(set) var runs: [TrainingRun] = []

    init() {
        workshops = Self.loadWorkshops().sorted { $0.updatedAt > $1.updatedAt }
        runs = Self.loadRuns().map(Self.recoverInterrupted).sorted { $0.createdAt > $1.createdAt }
    }

    /// A run persisted as actively preparing/loading/training means the app quit mid-run — nothing is
    /// running now, so present it as Paused (its saved checkpoints let it resume via the engine's
    /// autoResume; with no checkpoint yet it simply restarts fresh).
    private static func recoverInterrupted(_ run: TrainingRun) -> TrainingRun {
        guard run.status == .preparing || run.status == .loadingModel || run.status == .training else { return run }
        var r = run
        r.status = .paused
        r.runtime.message = "Interrupted — open it to resume."
        return r
    }

    // MARK: Persistence

    private static func loadWorkshops() -> [Workshop] {
        loadIndex(Workshop.self, from: AppPaths.trainingWorkshopsIndex, label: "workshops")
    }

    private static func loadRuns() -> [TrainingRun] {
        loadIndex(TrainingRun.self, from: AppPaths.trainingRunsIndex, label: "runs")
    }

    /// Decodes ONE array element, capturing a per-record decode failure as nil instead of
    /// aborting the whole array — so a single malformed record (e.g. after a schema change in a
    /// later chunk) can't vanish the entire index.
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// Static (non-isolated) so it can run from the actor's init. A clean index decodes whole;
    /// otherwise we QUARANTINE the unreadable original (`<label>.corrupt.<stamp>.json`), SALVAGE
    /// every still-decodable record, rewrite a clean index immediately, and log. Mirrors
    /// `GenerationStore.loadFromDisk` — training data (hours of compute, captioned datasets,
    /// published adapters) is far costlier to lose than a regenerable PNG, so it must never wipe.
    private static func loadIndex<T: Codable>(_ type: T.Type, from url: URL, label: String) -> [T] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        if let list = try? JSONDecoder().decode([T].self, from: data) {
            return list
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("\(label).corrupt.\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: quarantine)
        pruneQuarantines(in: url.deletingLastPathComponent(), label: label)
        if let lenient = try? JSONDecoder().decode([Failable<T>].self, from: data) {
            let salvaged = lenient.compactMap(\.value)
            if !salvaged.isEmpty {
                // Persist the salvage NOW so it survives a crash before the next save.
                if let clean = try? JSONEncoder().encode(salvaged) { try? clean.write(to: url, options: .atomic) }
                AppLog.error("\(label).json: salvaged \(salvaged.count) of \(lenient.count) record(s) — original saved as \(quarantine.lastPathComponent)")
                return salvaged
            }
        }
        AppLog.error("\(label).json corrupt → saved as \(quarantine.lastPathComponent)")
        return []
    }

    /// Quarantine files (`<label>.corrupt.<stamp>.json`) used to accumulate one per corruption
    /// event with nothing ever removing them. Keep the newest 3 per index — the just-written one
    /// included — which is plenty to recover from by hand without growing forever.
    private static func pruneQuarantines(in dir: URL, label: String, keep: Int = 3) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let prefix = "\(label).corrupt."
        let quarantines = entries.compactMap { u -> (stamp: Int, url: URL)? in
            let name = u.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".json"),
                  let stamp = Int(name.dropFirst(prefix.count).dropLast(".json".count)) else { return nil }
            return (stamp, u)
        }.sorted { $0.stamp > $1.stamp }                       // newest first
        for old in quarantines.dropFirst(keep) { try? fm.removeItem(at: old.url) }
    }

    private func persistWorkshops() throws {
        let data = try JSONEncoder().encode(workshops)
        try data.write(to: AppPaths.trainingWorkshopsIndex, options: .atomic)
    }

    private func persistRuns() throws {
        let data = try JSONEncoder().encode(runs)
        try data.write(to: AppPaths.trainingRunsIndex, options: .atomic)
    }

    // MARK: Reads

    func allWorkshops() -> [Workshop] { workshops }
    func allRuns() -> [TrainingRun] { runs }
    func runs(forWorkshop id: UUID) -> [TrainingRun] { runs.filter { $0.workshopId == id } }
    func run(_ id: UUID) -> TrainingRun? { runs.first { $0.id == id } }
    func workshop(_ id: UUID) -> Workshop? { workshops.first { $0.id == id } }

    // MARK: Workshop CRUD

    /// Insert or update a workshop (matched by id), stamping `updatedAt`, then persist.
    @discardableResult
    func upsert(_ workshop: Workshop) throws -> Workshop {
        var w = workshop
        w.updatedAt = Date()
        let snapshot = workshops
        if let idx = workshops.firstIndex(where: { $0.id == w.id }) {
            workshops[idx] = w
        } else {
            workshops.insert(w, at: 0)
        }
        workshops.sort { $0.updatedAt > $1.updatedAt }
        do { try persistWorkshops() } catch { workshops = snapshot; throw error }
        return w
    }

    /// Delete a workshop, its image folder, and any runs forged from it (with their output dirs).
    func deleteWorkshop(_ id: UUID) {
        workshops.removeAll { $0.id == id }
        try? FileManager.default.removeItem(
            at: AppPaths.trainingWorkshopsDir.appendingPathComponent(id.uuidString, isDirectory: true))
        // Don't claim a success the relaunch will contradict (same rule as CustomRecipeStore):
        // an unpersisted delete resurrects the workshop as a ghost whose files are gone.
        do { try persistWorkshops() }
        catch { AppLog.error("Workshop delete not persisted — it may reappear (fileless) on relaunch: \(error.localizedDescription)") }
        // Cascade: forged runs are snapshots, but their output dirs belong to this concept.
        let orphans = runs.filter { $0.workshopId == id }
        for r in orphans { deleteRun(r.id) }
    }

    // MARK: Run CRUD

    /// Insert or replace a run (matched by id), then persist.
    @discardableResult
    func upsert(_ run: TrainingRun) throws -> TrainingRun {
        let snapshot = runs
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            runs[idx] = run
        } else {
            runs.insert(run, at: 0)
        }
        do { try persistRuns() } catch { runs = snapshot; throw error }
        return run
    }

    /// Delete a run and its output dir (checkpoints, validation images, adapter).
    func deleteRun(_ id: UUID) {
        guard let run = runs.first(where: { $0.id == id }) else { return }
        runs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: run.outputDir)
        do { try persistRuns() }
        catch { AppLog.error("Run delete not persisted — “\(run.name)” may reappear (checkpoint-less) on relaunch: \(error.localizedDescription)") }
    }
}
