import Foundation

// ============================================================
//  Resumable HuggingFace downloader.
//
//  The engine's downloaders (swift-transformers HubApi + Flux2ModelDownloader) fetch each file
//  into a URLSession whole-file TEMP and only move it on completion — so a cancel / app-quit /
//  network stall mid-file throws away ALL in-flight bytes (a 4 GB encoder restarts from 0).
//
//  This downloader STREAMS bytes straight to a `<name>.part` file on disk via an HTTP `Range`
//  request, so an interruption keeps what it already got and the next attempt continues from the
//  exact offset — even across an app restart (the `.part` is persistent). It also auto-retries a
//  stalled connection (60 s idle timeout → resume). Files land FLAT (basename) in `destDir`,
//  exactly where the engine reads models back (ModelRegistry.localPath / findQwen3ModelPath).
//
//  Xet note: HF's `/resolve/` URL serves Xet-backed files as plain bytes via the xet-bridge CDN
//  WITH `Accept-Ranges: bytes` — so plain HTTP Range works for LFS and Xet alike. We deliberately
//  do NOT touch the native xet/CAS protocol (it doesn't support naive byte-range resume).
// ============================================================

enum ResumableDownloadError: LocalizedError {
    case badURL(String)
    case http(Int, String)        // status code, repo id
    case incomplete(String)       // file name
    case badHeader(String)        // file name — remote safetensors header unreadable

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Bad download URL: \(u)"
        case .http(let code, let repo):
            switch code {
            case 401, 403:
                return "Access denied (HTTP \(code)) for \(repo) — it's gated. Check your HuggingFace token and that you accepted the model's license on its page."
            case 404:
                return "Not found (HTTP 404): \(repo)."
            default:
                return "Download failed (HTTP \(code)) for \(repo)."
            }
        case .incomplete(let f):
            return "Download of \(f) ended early — it will resume on the next attempt."
        case .badHeader(let f):
            return "Couldn't read the safetensors header of \(f) — it may not be a safetensors file."
        }
    }
}

enum ResumableDownloader {
    struct RemoteFile: Sendable { let path: String; let size: Int64 }

    /// Download every model file of `repoId` (filtered to weights/config/tokenizer) into `destDir`,
    /// resuming any partial `.part` files. `subfolder` mirrors the engine layout (nil for Klein).
    static func download(
        repoId: String,
        revision: String = "main",
        subfolder: String? = nil,
        destDir: URL,
        token: String?,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        onProgress(0, "Preparing…")
        let all = try await listFiles(repoId: repoId, revision: revision, subfolder: subfolder, token: token)
        let files = all.filter { isWanted($0.path) }
        guard !files.isEmpty else { throw ResumableDownloadError.http(404, repoId) }

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + max(0, $1.size) }
        var prior: Int64 = 0

        for file in files {
            try Task.checkCancellation()
            let name = (file.path as NSString).lastPathComponent
            let finalURL = destDir.appendingPathComponent(name)

            // Already complete (size-matched) — skip, count it as done.
            if file.size > 0, fileSize(finalURL) == file.size {
                prior += file.size
                report(prior, total, name, onProgress)
                continue
            }

            let priorSnapshot = prior
            try await downloadFile(
                repoId: repoId, revision: revision, filePath: file.path,
                expectedSize: file.size, finalURL: finalURL, token: token
            ) { fileBytes in
                report(priorSnapshot + fileBytes, total, name, onProgress)
            }
            prior += file.size
        }
        onProgress(1.0, "Download complete")
    }

    // MARK: File list (HF tree API)

    static func listFiles(repoId: String, revision: String = "main", subfolder: String?, token: String?) async throws -> [RemoteFile] {
        var str = "https://huggingface.co/api/models/\(repoId)/tree/\(revision)"
        if let subfolder, !subfolder.isEmpty { str += "/\(subfolder)" }
        guard let url = URL(string: str) else { throw ResumableDownloadError.badURL(str) }
        var req = URLRequest(url: url)
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ResumableDownloadError.http(code, repoId) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return json.compactMap { item in
            guard (item["type"] as? String) == "file", let path = item["path"] as? String else { return nil }
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0
            return RemoteFile(path: path, size: size)
        }
    }

    private static func isWanted(_ path: String) -> Bool {
        path.hasSuffix(".safetensors") || path.hasSuffix(".json")
            || (path as NSString).lastPathComponent == "tokenizer.model"
    }

    // MARK: Single named file (LoRA URL import)

    /// Download ONE file of `repoId` into `destDir` (flat basename), with the same Range-resume /
    /// retry / parallel-chunk machinery as the model downloads. Returns the final file URL.
    static func downloadSingleFile(
        repoId: String,
        revision: String = "main",
        filePath: String,
        expectedSize: Int64,
        destDir: URL,
        token: String?,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let name = (filePath as NSString).lastPathComponent
        let finalURL = destDir.appendingPathComponent(name)
        if expectedSize > 0, fileSize(finalURL) == expectedSize {   // already complete
            onProgress(1.0, "Download complete")
            return finalURL
        }
        try await downloadFile(repoId: repoId, revision: revision, filePath: filePath,
                               expectedSize: expectedSize, finalURL: finalURL, token: token) { bytes in
            report(bytes, expectedSize, name, onProgress)
        }
        onProgress(1.0, "Download complete")
        return finalURL
    }

    /// Fetch JUST the safetensors JSON header of a remote file via HTTP Range (8-byte length
    /// prefix, then the header bytes) — the pre-flight compatibility gate reads tier/format
    /// from this without downloading the tensor data.
    static func fetchSafetensorsHeader(
        repoId: String, revision: String = "main", filePath: String, token: String?
    ) async throws -> Data {
        let name = (filePath as NSString).lastPathComponent
        let prefix = try await fetchRange(repoId: repoId, revision: revision, filePath: filePath,
                                          from: 0, to: 7, token: token)
        guard prefix.count == 8 else { throw ResumableDownloadError.badHeader(name) }
        let headerLen = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }   // little-endian
        guard headerLen > 0, headerLen < 50_000_000 else {   // same sanity cap as the local inspector
            throw ResumableDownloadError.badHeader(name)
        }
        let header = try await fetchRange(repoId: repoId, revision: revision, filePath: filePath,
                                          from: 8, to: 8 + Int64(headerLen) - 1, token: token)
        guard header.count == Int(headerLen) else { throw ResumableDownloadError.badHeader(name) }
        return header
    }

    /// GET an absolute byte range of `/resolve/` content. Streams via AsyncBytes and stops as
    /// soon as it has the requested window, so a server that ignores Range (200, full body)
    /// costs only the skipped prefix — never a whole-file buffer.
    private static func fetchRange(
        repoId: String, revision: String, filePath: String,
        from: Int64, to: Int64, token: String?
    ) async throws -> Data {
        let str = "https://huggingface.co/\(repoId)/resolve/\(revision)/\(filePath)"
        guard let url = URL(string: str) else { throw ResumableDownloadError.badURL(str) }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")

        // Same cross-host Authorization strip as the streaming delegates — this range GET
        // carries the token and follows the /resolve/ 302 to the CDN like everything else.
        let (bytes, resp) = try await URLSession.shared.bytes(for: req, delegate: AuthRedirectStripper.shared)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 206 || code == 200 else { throw ResumableDownloadError.http(code, repoId) }
        // Trust the ACTUAL range start, not the status code alone: the HF CDN has been seen
        // answering a Range request with the whole file as a 206 (Content-Range start 0) — see
        // StreamToFileDelegate. Blindly assuming a 206 body starts at `from` would shift the
        // header window by the 8-byte prefix and fail the pre-flight on a perfectly good file.
        var skip = Int(from)                          // 200 = body starts at byte 0
        if code == 206 {
            let start = contentRangeStart(http?.value(forHTTPHeaderField: "Content-Range"))
            let actualStart = start >= 0 ? start : from   // absent header → assume the echoed offset
            guard actualStart <= from else {              // body starts PAST the window → unusable
                throw ResumableDownloadError.badHeader((filePath as NSString).lastPathComponent)
            }
            skip = Int(from - actualStart)
        }
        let want = Int(to - from + 1)
        var data = Data()
        data.reserveCapacity(want)
        for try await byte in bytes {
            if skip > 0 { skip -= 1; continue }
            data.append(byte)
            if data.count >= want { break }           // dropping the sequence cancels the task
        }
        return data
    }

    // MARK: Shared transfer plumbing

    /// One URLSession recipe for BOTH transfer paths (sequential stream + every parallel
    /// segment) — they used to carry duplicated literal copies of this config, which is
    /// exactly how a future tweak would fix one path and silently miss the other.
    /// 60 s idle timeout is what turns a stalled connection into a resume-retry; the 24 h
    /// resource ceiling covers multi-GB weights on slow links.
    private static func makeTransferSession(delegate: URLSessionDataDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60          // idle/stall timeout → triggers a resume-retry
        cfg.timeoutIntervalForResource = 24 * 3600  // whole-file ceiling (multi-GB on slow links)
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    /// Backoff before resuming after a transient failure (stall/timeout/drop) — shared by
    /// the sequential and the chunked retry loops.
    private static let retryBackoffNanos: UInt64 = 2_000_000_000

    // MARK: Single file (Range-resume + retry; large files go parallel-chunked)

    private static func downloadFile(
        repoId: String, revision: String, filePath: String,
        expectedSize: Int64, finalURL: URL, token: String?,
        onFileBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let partURL = URL(fileURLWithPath: finalURL.path + ".part")
        let sidecarURL = URL(fileURLWithPath: finalURL.path + ".part.chunks")
        // Sequential-path revision validator (see PartMeta) — same lifecycle as the .chunks
        // sidecar: created with the first response, removed on promote/restart.
        let metaURL = URL(fileURLWithPath: finalURL.path + ".part.meta")

        // Belt-and-braces against the preallocated-.part-masquerades-as-complete corruption:
        // a chunk-sized .part of EXACTLY expectedSize with NO sidecar is never a legitimate
        // sequential leftover. Proof against the promote path below: the sequential loop
        // breaks the moment fileSize(partURL) == expectedSize and the very same call then
        // moveItem()s the .part away — a genuinely-complete sequential .part only survives a
        // crash in the instants between its last byte and that rename. The overwhelmingly
        // likely origin of this state is the pre-fix chunked path, which truncated the .part
        // to full size BEFORE its first (and silently try?-failing) sidecar persist — leaving
        // a ZERO-FILLED shell that the next attempt would classify as a completed legacy
        // sequential download and promote as real weights (only 4B-8bit has a SHA pin to
        // catch that). The two cases are indistinguishable from here, so delete and restart:
        // at worst that re-downloads one genuinely-complete file in the vanishingly rare
        // crash-before-rename case. Correctness wins.
        let hasSidecar = FileManager.default.fileExists(atPath: sidecarURL.path)
        if !hasSidecar, expectedSize >= chunkThreshold, fileSize(partURL) == expectedSize {
            try? FileManager.default.removeItem(at: partURL)
            try? FileManager.default.removeItem(at: metaURL)
        }

        // PARALLEL fast path for big files: N concurrent range streams into a preallocated
        // .part (the single-stream path leaves most of the link idle — FluxForge's downloader
        // was ~7× faster on the same 8 GB for exactly this reason). A pre-existing SEQUENTIAL
        // .part (no chunk map) keeps its bytes and stays on the sequential path (except the
        // suspicious exactly-full-size case handled above).
        let legacySequentialPart = fileSize(partURL) > 0 && !hasSidecar
        var chunkedDone = false
        if expectedSize >= chunkThreshold, !legacySequentialPart {
            do {
                try await downloadFileChunked(repoId: repoId, revision: revision, filePath: filePath,
                                              expectedSize: expectedSize, partURL: partURL,
                                              sidecarURL: sidecarURL, token: token, onFileBytes: onFileBytes)
                chunkedDone = true
            } catch is RangeUnsupported {
                // Server won't serve mid-file ranges (or preallocation failed) — clean the
                // chunked scaffolding and fall back to the proven sequential stream.
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.removeItem(at: sidecarURL)
            }
            // Every other error (incl. cancellation) already went through the chunked retry
            // loop and its sidecar persist — rethrow happened inside downloadFileChunked.
        }

        let maxAttempts = 6
        var attempt = 0
        while !chunkedDone {
            attempt += 1
            try Task.checkCancellation()

            var offset = max(0, fileSize(partURL))
            if expectedSize > 0, offset > expectedSize {      // corrupt/over-long partial → restart
                try? FileManager.default.removeItem(at: partURL); offset = 0
                try? FileManager.default.removeItem(at: metaURL)   // validator described the removed bytes
            }
            if expectedSize > 0, offset == expectedSize { break }   // .part already complete

            // Revision-splice gate: a bare `bytes=offset-` resumes blindly, so a repo
            // force-pushed between attempts (or across an app restart) with a SAME-SIZE file
            // would silently splice two revisions into one .part — corrupt weights that pass
            // the size check. The validator captured from this download's first response
            // lives in .part.meta; a resume sends it as `If-Range`, making the Range
            // conditional: on mismatch the server answers 200 + full body, and
            // StreamToFileDelegate already truncates + restarts on any 200 (verified below).
            // A .part with NO meta (pre-fix residue) can't be validated at all → restart it
            // from zero, once. An EMPTY stored validator means the server offered none on the
            // first response — resume unvalidated (the pre-fix behavior) rather than looping
            // fruitless restarts against a validator-less server.
            var ifRange: String? = nil
            if offset > 0 {
                if let stored = loadPartValidator(metaURL) {
                    ifRange = stored.isEmpty ? nil : stored
                } else {
                    try? FileManager.default.removeItem(at: partURL)
                    offset = 0
                }
            }

            do {
                try await fetchInto(partURL: partURL, metaURL: metaURL, repoId: repoId,
                                    revision: revision, filePath: filePath, offset: offset,
                                    ifRange: ifRange, token: token,
                                    onFileBytes: onFileBytes)
                break   // success
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch {
                if attempt >= maxAttempts { throw error }
                // transient (stall/timeout/drop) → back off, then resume from the larger .part
                try? await Task.sleep(nanoseconds: retryBackoffNanos)
            }
        }

        // Promote the completed .part to the final file.
        if expectedSize > 0, fileSize(partURL) != expectedSize {
            throw ResumableDownloadError.incomplete(finalURL.lastPathComponent)
        }
        // Unknown tree-API size (some config/index JSON report 0): a 0-byte .part means the body
        // never arrived — retry instead of promoting an empty stub the engine would later choke on.
        if expectedSize <= 0, fileSize(partURL) <= 0 {
            throw ResumableDownloadError.incomplete(finalURL.lastPathComponent)
        }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        try? FileManager.default.removeItem(at: metaURL)   // its .part is promoted — validator done
    }

    private static func fetchInto(
        partURL: URL, metaURL: URL, repoId: String, revision: String, filePath: String,
        offset: Int64, ifRange: String?, token: String?,
        onFileBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let str = "https://huggingface.co/\(repoId)/resolve/\(revision)/\(filePath)"
        guard let url = URL(string: str) else { throw ResumableDownloadError.badURL(str) }
        var req = URLRequest(url: url)
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            // Conditional resume: a changed revision returns 200-full-restart instead of
            // silently serving another revision's tail (see the gate in downloadFile).
            if let ifRange { req.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        }

        let delegate = StreamToFileDelegate(partURL: partURL, metaURL: metaURL, requestedOffset: offset, repoId: repoId, onFileBytes: onFileBytes)
        let session = makeTransferSession(delegate: delegate)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: req)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.continuation = cont
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Parallel chunked download

    /// Files at least this large download as parallel range chunks (small ones gain nothing).
    private static let chunkThreshold: Int64 = 64 << 20    // 64 MB
    private static let chunkWorkers = 6                    // concurrent range streams per file
    private static let chunkSize: Int64 = 128 << 20        // 128 MB segments (an 8 GB file ≈ 62)

    /// One segment of a chunked download; the sidecar persists the array so a quit/cancel
    /// resumes every segment from its exact offset.
    fileprivate struct ChunkState: Codable {
        var start: Int64      // absolute offset in the file
        var length: Int64
        var done: Int64
    }

    /// Version stamp shared by BOTH sidecar formats (.part.chunks container + .part.meta).
    /// Bump it whenever the meaning of persisted fields changes — an old-version (or
    /// unversioned) sidecar is REJECTED on load, never migrated.
    fileprivate static let sidecarVersion = 2

    /// v2 `.part.chunks` container. v1 was a BARE `[ChunkState]` JSON array whose `done`
    /// values could be INFLATED: the pre-rewrite accounting folded fire-and-forget display
    /// flushes into the persisted counters, so a retry could persist `done` past bytes that
    /// were never written. Trusting a v1 map verbatim would inherit those zero-filled holes
    /// into a file that then passes the size check. The version gate makes rejection explicit;
    /// a v1 array also fails the container decode outright (array vs object). On rejection the
    /// .part file is kept and the chunks restart from zero over it.
    fileprivate struct ChunkSidecar: Codable {
        var version: Int
        /// Revision validator (ETag, or Last-Modified fallback) of the repo file these bytes
        /// came from; "" = the server offered none (resume then proceeds unvalidated).
        var etag: String
        var chunks: [ChunkState]
    }

    /// Sequential-path `.part.meta` sidecar: just the revision validator for the plain-stream
    /// `.part` (which has no chunk map to carry it). Same version gate as the chunk sidecar.
    fileprivate struct PartMeta: Codable {
        var version: Int
        var etag: String   // "" = server offered no validator → resume unvalidated
    }

    /// Chunking impossible (server ignored a mid-file Range / preallocation failed) —
    /// the caller falls back to the sequential stream. Never surfaced to the user.
    fileprivate struct RangeUnsupported: Error {}

    /// Best-effort persist for the RUNNING download (throttled updates + persistNow). The
    /// INITIAL persist of a fresh map deliberately does NOT go through here — it must throw
    /// (see downloadFileChunked): losing a mid-run update only under-counts progress, but
    /// losing the very first map would leave a full-size .part unclassifiable.
    fileprivate static func persistSidecar(_ chunks: [ChunkState], etag: String, to url: URL) {
        if let data = try? JSONEncoder().encode(ChunkSidecar(version: sidecarVersion, etag: etag, chunks: chunks)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Stored validator of a sequential `.part` (nil = no/invalid/old-version meta → the
    /// .part can't be validated and must restart; "" = validated as "server offers none").
    private static func loadPartValidator(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(PartMeta.self, from: data),
              meta.version == sidecarVersion else { return nil }
        return meta.etag
    }

    /// Written by StreamToFileDelegate BEFORE the first body byte lands (fileprivate for that).
    fileprivate static func storePartValidator(_ etag: String, to url: URL) {
        if let data = try? JSONEncoder().encode(PartMeta(version: sidecarVersion, etag: etag)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Current revision validator of a repo file: the ETag (Last-Modified fallback) of a HEAD
    /// on the /resolve/ URL. Best-effort — nil when the request fails or carries no validator,
    /// in which case splice-validation degrades to the pre-fix "resume blindly" for this file
    /// (refusing a multi-GB download over a missing header would hurt more).
    ///
    /// WHY a HEAD probe (design choice, fix #4): the chunked path can't lean on If-Range the
    /// way the sequential path does — SegmentDelegate must refuse ANY 200 body (writing a
    /// full-file body at a mid-file offset corrupts the other workers' segments), so the
    /// 200-full-restart a mismatched If-Range produces is unusable there. Comparing validators
    /// once, BEFORE spawning workers, is the least complex variant that still catches the
    /// dangerous case: resuming yesterday's half-download against a force-pushed same-size
    /// file. (A force-push in the seconds mid-transfer remains theoretically possible — the
    /// same exposure any single-shot HTTP download has.)
    private static func fetchValidator(repoId: String, revision: String, filePath: String,
                                       token: String?) async -> String? {
        let str = "https://huggingface.co/\(repoId)/resolve/\(revision)/\(filePath)"
        guard let url = URL(string: str) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // The redirect-stripping delegate is NOT optional here: /resolve/ HEADs 302 to the CDN,
        // and URLSession.shared alone would re-send the Bearer there (token exposure) — and
        // S3-style hosts REJECT doubly-authenticated requests, so the probe would fail for
        // exactly the gated repos this validator protects, silently disabling the revision gate.
        guard let (_, resp) = try? await URLSession.shared.data(for: req, delegate: AuthRedirectStripper.shared),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
    }

    private static func downloadFileChunked(
        repoId: String, revision: String, filePath: String,
        expectedSize: Int64, partURL: URL, sidecarURL: URL, token: String?,
        onFileBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        // Revision validator FIRST (one cheap HEAD per multi-GB file): the resume gate below
        // compares it against the sidecar's stored value, and a fresh sidecar records it.
        // See fetchValidator for why a HEAD probe and not per-segment If-Range.
        let currentValidator = await fetchValidator(repoId: repoId, revision: revision,
                                                    filePath: filePath, token: token)
        try Task.checkCancellation()

        // Load a resumable chunk map, or preallocate a fresh (sparse) full-size .part + map.
        var resumed: [ChunkState]? = nil
        var etag = currentValidator ?? ""
        if let data = try? Data(contentsOf: sidecarURL),
           let saved = try? JSONDecoder().decode(ChunkSidecar.self, from: data),
           saved.version == sidecarVersion,   // old/unknown versions are UNTRUSTED — see ChunkSidecar
           !saved.chunks.isEmpty,
           saved.chunks.reduce(Int64(0), { $0 + $1.length }) == expectedSize,
           saved.chunks.allSatisfy({ $0.done >= 0 && $0.done <= $0.length }),
           fileSize(partURL) == expectedSize {
            // Structurally sound v2 map. Revision-splice gate before trusting it: resume ONLY
            // when the bytes on disk are provably of the same repo revision. Both validators
            // present but different = the repo was force-pushed (with a same-size file — the
            // size checks can't see it) → the .part holds another revision's bytes → discard
            // the map and restart the chunks from zero. Either side missing = can't compare →
            // resume anyway (best-effort: discarding GBs over a header hiccup would hurt more
            // than the pre-fix status quo this degrades to).
            if let current = currentValidator, !saved.etag.isEmpty, saved.etag != current {
                resumed = nil
            } else {
                resumed = saved.chunks
                if !saved.etag.isEmpty { etag = saved.etag }
            }
        }
        // (A rejected/missing sidecar keeps the .part file — the fresh all-zero map below
        // simply re-downloads every byte over it.)

        let chunks: [ChunkState]
        if let resumed {
            chunks = resumed
        } else {
            var fresh: [ChunkState] = []
            var offset: Int64 = 0
            while offset < expectedSize {
                let len = min(chunkSize, expectedSize - offset)
                fresh.append(ChunkState(start: offset, length: len, done: 0))
                offset += len
            }
            // CRASH ORDERING — the sidecar is written STRICTLY BEFORE the full-size truncate,
            // and this first persist THROWS. The old order (truncate first, sidecar later via
            // a silent try?) opened the corruption this file was audited for: a quit/crash/
            // failed persist between the two left a full-size ZERO-FILLED .part with no
            // sidecar, which the next attempt classified as a completed legacy sequential
            // download and promoted as real weights. Writing the (tiny, atomic) all-zero map
            // first means a crash at any point leaves either nothing, a sidecar without a
            // .part (rebuilt fresh next time), or a consistent sidecar + .part pair. And if
            // this very first persist can't be written (disk full / permissions), the download
            // must FAIL LOUDLY here — falling through would resurrect the zero-fill bug.
            let data = try JSONEncoder().encode(ChunkSidecar(version: sidecarVersion, etag: etag, chunks: fresh))
            try data.write(to: sidecarURL, options: .atomic)

            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: partURL) else {
                throw RangeUnsupported()   // caller cleans .part + sidecar, falls back sequential
            }
            do { try handle.truncate(atOffset: UInt64(expectedSize)) }
            catch { try? handle.close(); throw RangeUnsupported() }
            try? handle.close()
            chunks = fresh
        }

        let coordinator = ChunkCoordinator(chunks: chunks, etag: etag, sidecarURL: sidecarURL, onTotal: onFileBytes)
        let maxAttempts = 6
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0 ..< chunkWorkers {
                        group.addTask {
                            while let job = await coordinator.claimNext() {
                                try Task.checkCancellation()
                                try await fetchSegment(job, repoId: repoId, revision: revision,
                                                       filePath: filePath, partURL: partURL,
                                                       token: token, coordinator: coordinator)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                break
            } catch is CancellationError {
                await coordinator.persistNow(); throw CancellationError()
            } catch let e as URLError where e.code == .cancelled {
                await coordinator.persistNow(); throw CancellationError()
            } catch is RangeUnsupported {
                await coordinator.persistNow(); throw RangeUnsupported()
            } catch {
                await coordinator.persistNow()
                if attempt >= maxAttempts { throw error }
                try? await Task.sleep(nanoseconds: retryBackoffNanos)   // transient → back off, resume
                await coordinator.requeueUnfinished()
            }
        }

        await coordinator.persistNow()
        guard await coordinator.allDone else {
            throw ResumableDownloadError.incomplete(partURL.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    private static func fetchSegment(
        _ job: ChunkCoordinator.Job, repoId: String, revision: String, filePath: String,
        partURL: URL, token: String?, coordinator: ChunkCoordinator
    ) async throws {
        let from = job.start + job.done
        let to = job.start + job.length - 1
        guard from <= to else { await coordinator.release(job.index); return }

        let str = "https://huggingface.co/\(repoId)/resolve/\(revision)/\(filePath)"
        guard let url = URL(string: str) else { throw ResumableDownloadError.badURL(str) }
        var req = URLRequest(url: url)
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")

        let index = job.index
        // The delegate's flushes feed ONLY the progress display — they're posted as
        // fire-and-forget Tasks from URLSession's queue, so they are unordered and can land
        // arbitrarily late. The AUTHORITATIVE per-chunk accounting happens below, in this
        // awaited scope, from the delegate's synchronous byte counter.
        let delegate = SegmentDelegate(partURL: partURL, writeOffset: from, repoId: repoId,
                                       onBytes: { n in Task { await coordinator.noteDisplayBytes(index, n) } })
        let session = makeTransferSession(delegate: delegate)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: req)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    delegate.continuation = cont
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            // AUTHORITATIVE accounting, failure path: credit exactly the bytes this attempt
            // actually wrote (they sit at their correct absolute offsets in the .part) and
            // release the claim. Awaited HERE — strictly before the retry loop can requeue and
            // re-claim the chunk — so a late display flush can never be double-counted into
            // the resume offset (that was race (b): overlapped bytes marked done → the
            // preallocated .part promoted with a zero-filled hole in the chunk's tail).
            await coordinator.attemptEnded(index, wrote: delegate.bytesWritten)
            throw error
        }
        // AUTHORITATIVE accounting, success path: runs before this group task returns, i.e.
        // strictly before waitForAll → allDone — so the old race (a), a final fire-and-forget
        // flush landing after the completion check and yielding a spurious `.incomplete` on a
        // fully-written file, can no longer exist. done == length keeps the chunk unclaimable.
        await coordinator.attemptEnded(index, wrote: delegate.bytesWritten)
    }

    // MARK: helpers

    /// Start byte of a "Content-Range: bytes START-END/TOTAL" header (-1 if absent/unparseable).
    /// (Same parser as the two delegates below — they're private classes, so it's mirrored here.)
    private static func contentRangeStart(_ header: String?) -> Int64 {
        guard let header, let r = header.range(of: "bytes ") else { return -1 }
        let rest = header[r.upperBound...]
        guard let dash = rest.firstIndex(of: "-") else { return -1 }
        return Int64(rest[rest.startIndex..<dash].trimmingCharacters(in: .whitespaces)) ?? -1
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return -1 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static func report(_ done: Int64, _ total: Int64, _ name: String,
                               _ onProgress: @escaping @Sendable (Double, String) -> Void) {
        let frac = total > 0 ? min(0.999, Double(done) / Double(total)) : 0
        onProgress(frac, "Downloading \(name) · \(Int(frac * 100))%")
    }
}

/// Hands out unfinished segments to workers and owns the AUTHORITATIVE per-chunk byte
/// accounting. Two strictly separated inputs:
///
///  • `attemptEnded` — awaited by the worker AFTER its segment's continuation resumed. The
///    ONLY mutator of `chunks[].done`, which is both the completion criterion (`allDone`)
///    and the per-chunk resume offset (`claimNext` / the persisted sidecar).
///  • `noteDisplayBytes` — fire-and-forget flushes from the URLSession delegates. They feed
///    a display-only overlay so the progress bar moves mid-segment; they can arrive late or
///    out of order, which is exactly why they must never touch `chunks[].done`. (The old
///    design fed them into the real counters: a flush landing after waitForAll produced a
///    spurious `.incomplete` on a complete file, and one landing after a retry re-claimed
///    the chunk double-counted overlapped bytes — a chunk read "done" with a never-written
///    tail, and the promoted file passed the size check because the .part is preallocated.)
///
/// The sidecar is the v2 container (version + revision etag + [ChunkState]); v1 bare-array
/// sidecars are REJECTED on load (their `done` could be inflated by the old display-byte
/// accounting) and the chunks restart from zero. `done` is only ever advanced from awaited
/// attempt results, and the segment delegate fsyncs its handle before the continuation
/// resumes — so by the time a `done` value reaches the persisted sidecar, the bytes it
/// covers are durable on disk. A hard crash/power loss can therefore lose only the current
/// attempt's in-flight tail, which UNDER-counts (those bytes re-download over the same
/// offsets) — never over-counts.
private actor ChunkCoordinator {
    struct Job: Sendable { let index: Int; let start: Int64; let length: Int64; let done: Int64 }

    private var chunks: [ResumableDownloader.ChunkState]
    private var claimed: Set<Int> = []
    /// Display-only bytes of each claimed chunk's CURRENT attempt. Never persisted, never
    /// folded into `chunks[].done`.
    private var displayInFlight: [Int: Int64] = [:]
    private let totalLength: Int64
    /// Revision validator recorded in every persist — the resume gate compares it against a
    /// fresh HEAD before trusting the map (see downloadFileChunked).
    private let etag: String
    private let sidecarURL: URL
    private let onTotal: @Sendable (Int64) -> Void
    private var lastPersist = Date()
    private var lastReported: Int64 = 0

    init(chunks: [ResumableDownloader.ChunkState], etag: String, sidecarURL: URL, onTotal: @escaping @Sendable (Int64) -> Void) {
        self.chunks = chunks
        self.totalLength = chunks.reduce(Int64(0)) { $0 + $1.length }
        self.etag = etag
        self.sidecarURL = sidecarURL
        self.onTotal = onTotal
    }

    func claimNext() -> Job? {
        for (i, c) in chunks.enumerated() where c.done < c.length && !claimed.contains(i) {
            claimed.insert(i)
            displayInFlight[i] = 0
            return Job(index: i, start: c.start, length: c.length, done: c.done)
        }
        return nil
    }

    /// Display-only. A flush that lands after its attempt ended is dropped (the chunk is
    /// unclaimed or finished by then); the worst a surviving late one can do is nudge the
    /// progress BAR, never the accounting.
    func noteDisplayBytes(_ index: Int, _ bytes: Int64) {
        guard claimed.contains(index), chunks.indices.contains(index),
              chunks[index].done < chunks[index].length else { return }
        displayInFlight[index, default: 0] += bytes
        reportTotal()
    }

    /// AUTHORITATIVE: fold an attempt's actually-written bytes into the chunk — success and
    /// failure alike, since either way those bytes are on disk at their correct offsets —
    /// and release the claim. Reached only from awaited worker code, so its ordering against
    /// retry re-claims and the final `allDone` check is guaranteed by structured concurrency,
    /// not by delegate-callback timing.
    func attemptEnded(_ index: Int, wrote: Int64) {
        guard chunks.indices.contains(index) else { return }
        chunks[index].done = min(chunks[index].length, chunks[index].done + max(0, wrote))
        displayInFlight[index] = nil
        claimed.remove(index)                       // done == length keeps it unclaimable
        reportTotal()
        if Date().timeIntervalSince(lastPersist) > 2 {   // same cadence as before the fix
            lastPersist = Date()
            ResumableDownloader.persistSidecar(chunks, etag: etag, to: sidecarURL)
        }
    }

    /// Progress display = authoritative done + the current attempts' in-flight overlay,
    /// throttled like the sequential path (~every 4 MB) and clamped to the file size.
    private func reportTotal() {
        let done = chunks.reduce(Int64(0)) { $0 + $1.done }
        let total = min(totalLength, done + displayInFlight.values.reduce(0, +))
        if total - lastReported >= 4_000_000 {
            lastReported = total
            onTotal(total)
        }
    }

    /// Degenerate claim (segment already complete at claim time) — un-claim, nothing to account.
    func release(_ index: Int) {
        claimed.remove(index)
        displayInFlight[index] = nil
    }

    func requeueUnfinished() {
        claimed.removeAll()
        displayInFlight.removeAll()
    }
    func persistNow() { ResumableDownloader.persistSidecar(chunks, etag: etag, to: sidecarURL) }
    var allDone: Bool { chunks.allSatisfy { $0.done >= $0.length } }
}

/// Task-level delegate for the ONE-SHOT token-carrying requests (the validator HEAD and the
/// safetensors-header range GETs): strips Authorization when a redirect leaves the original
/// host — the same rule the two streaming delegates implement below. Stateless, so one shared
/// instance serves every request; passed per-call via `URLSession.shared.data(for:delegate:)`.
private final class AuthRedirectStripper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = AuthRedirectStripper()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        if let origHost = task.originalRequest?.url?.host?.lowercased(),
           req.url?.host?.lowercased() != origHost {
            req.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(req)
    }
}

/// Streams one 206 range body into the preallocated `.part` at an absolute offset. Anything
/// but a 206 whose Content-Range starts EXACTLY at the requested offset is refused — writing
/// a full 200 body at a mid-file offset would corrupt the other workers' segments.
private final class SegmentDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partURL: URL
    private let writeOffset: Int64
    private let repoId: String
    private let onBytes: @Sendable (Int64) -> Void   // DISPLAY-ONLY flushes, every ~2 MB
    var continuation: CheckedContinuation<Void, Error>?

    /// Bytes actually written to the .part this attempt — the AUTHORITATIVE figure the
    /// awaiting task folds into the chunk map. Safe without a lock: all writes happen on
    /// URLSession's serial delegate queue, and the reader only looks after the continuation
    /// resumed (didCompleteWithError is the final callback, so the resume orders every
    /// write strictly before the read).
    private(set) var bytesWritten: Int64 = 0

    private var handle: FileHandle?
    private var unflushed: Int64 = 0
    private var earlyError: Error?

    init(partURL: URL, writeOffset: Int64, repoId: String, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.partURL = partURL
        self.writeOffset = writeOffset
        self.repoId = repoId
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard code == 206 else {
            earlyError = code == 200 ? ResumableDownloader.RangeUnsupported()
                                     : ResumableDownloadError.http(code, repoId)
            completionHandler(.cancel)
            return
        }
        let start = Self.contentRangeStart(http?.value(forHTTPHeaderField: "Content-Range"))
        guard start < 0 || start == writeOffset else {   // wrong offset → do NOT write it
            earlyError = ResumableDownloader.RangeUnsupported()
            completionHandler(.cancel)
            return
        }
        handle = try? FileHandle(forWritingTo: partURL)
        do { try handle?.seek(toOffset: UInt64(writeOffset)) }
        catch { handle = nil }
        guard handle != nil else {
            earlyError = ResumableDownloadError.incomplete(partURL.lastPathComponent)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // After a failed write, URLSession can still deliver data callbacks already queued
        // before the cancel landed. Writing those would skip the failed span (the FileHandle
        // position never advanced past it) yet still count the bytes — a silent hole credited
        // as done. Once this attempt errored, drop everything.
        guard earlyError == nil else { return }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            earlyError = error
            dataTask.cancel()
            return
        }
        bytesWritten += Int64(data.count)   // authoritative counter — read after the continuation resumes
        unflushed += Int64(data.count)
        if unflushed >= 2_000_000 {
            onBytes(unflushed)
            unflushed = 0
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // fsync BEFORE the continuation resumes (crash-ordering, fix for the power-loss
        // over-count): attemptEnded() — which runs strictly AFTER this resume and may persist
        // the sidecar — credits `bytesWritten` as done. The multi-MB data writes sit in the
        // page cache while the sidecar's atomic rename is tiny and commits first; after a
        // power loss the persisted map would then claim MORE bytes than the .part actually
        // holds, and the hole would be promoted inside "complete" weights. Synchronizing the
        // handle here makes every byte that can ever reach a persisted `done` durable FIRST.
        // Runs on failure paths too — attemptEnded credits a failed attempt's bytes as well.
        // Cost: one fsync per segment attempt (~128 MB); the coordinator's 2 s persist
        // cadence is unchanged.
        if bytesWritten > 0 { try? handle?.synchronize() }
        try? handle?.close()
        handle = nil
        if unflushed > 0 { onBytes(unflushed); unflushed = 0 }   // last display flush (UI only)
        if let earlyError {
            continuation?.resume(throwing: earlyError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: ())
        }
        continuation = nil
    }

    /// Cross-host redirect (huggingface.co → xet-bridge/CDN): URLSession re-sends the original
    /// headers on the redirected request, which would hand the HuggingFace Bearer token to
    /// whatever host the redirect names. Strip Authorization the moment the redirect leaves
    /// the original host; everything else (Range) must survive — the CDN is exactly where the
    /// range is served from (S3-style hosts even REJECT requests carrying a foreign auth header).
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        if let origHost = task.originalRequest?.url?.host?.lowercased(),
           req.url?.host?.lowercased() != origHost {
            req.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(req)
    }

    /// Start byte of a "Content-Range: bytes START-END/TOTAL" header (-1 if absent/unparseable).
    private static func contentRangeStart(_ header: String?) -> Int64 {
        guard let header, let r = header.range(of: "bytes ") else { return -1 }
        let rest = header[r.upperBound...]
        guard let dash = rest.firstIndex(of: "-") else { return -1 }
        return Int64(rest[rest.startIndex..<dash].trimmingCharacters(in: .whitespaces)) ?? -1
    }
}

/// Streams an HTTP response body straight to a `.part` file (append on 206, truncate on 200).
/// URLSession serializes these delegate callbacks (delegateQueue: nil → a private serial queue),
/// so the mutable state here needs no extra locking.
private final class StreamToFileDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partURL: URL
    private let metaURL: URL   // revision-validator sidecar for the sequential .part
    private let requestedOffset: Int64
    private let repoId: String
    private let onFileBytes: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?

    private var handle: FileHandle?
    private var base: Int64 = 0
    private var received: Int64 = 0
    private var lastReported: Int64 = 0
    private var earlyError: Error?

    init(partURL: URL, metaURL: URL, requestedOffset: Int64, repoId: String, onFileBytes: @escaping @Sendable (Int64) -> Void) {
        self.partURL = partURL
        self.metaURL = metaURL
        self.requestedOffset = requestedOffset
        self.repoId = repoId
        self.onFileBytes = onFileBytes
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 206:                       // partial — append, but TRUST the server's actual range start
            let start = Self.contentRangeStart((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"))
            if start < 0 || start == requestedOffset {
                base = requestedOffset              // no/echoed header → resume at our requested offset
                openHandle(truncate: false)
            } else if start == 0 {                  // CDN sent the whole file as a 206 → start fresh
                base = 0
                openHandle(truncate: true)
            } else {                                // 206 from a different offset → restart cleanly next attempt
                earlyError = ResumableDownloadError.incomplete(partURL.lastPathComponent)
                completionHandler(.cancel)
                return
            }
        case 200:                       // full body (no range / server ignored it) — start fresh
            base = 0
            openHandle(truncate: true)
        default:
            earlyError = ResumableDownloadError.http(code, repoId)
            completionHandler(.cancel)
            return
        }
        if handle == nil {              // FileHandle open failed (disk full / perms) — don't silently 0-download
            earlyError = ResumableDownloadError.incomplete(partURL.lastPathComponent)
            completionHandler(.cancel)
            return
        }
        // Record the revision validator BEFORE the first body byte can land in the .part —
        // a crash mid-stream must never leave resumable bytes whose revision wasn't recorded
        // (the resume gate in downloadFile would then restart them from zero). A fresh start
        // (base == 0: plain 200, or a CDN whole-file 206) overwrites with the new revision's
        // validator; a mid-file resume keeps the existing record — the bytes already on disk
        // are of THAT revision, and If-Range guaranteed this response matches it. "" is a
        // real value: "server offered no validator" → later resumes proceed unvalidated
        // instead of restart-looping.
        if base == 0 || !FileManager.default.fileExists(atPath: metaURL.path) {
            let http = response as? HTTPURLResponse
            let validator = http?.value(forHTTPHeaderField: "ETag")
                ?? http?.value(forHTTPHeaderField: "Last-Modified") ?? ""
            ResumableDownloader.storePartValidator(validator, to: metaURL)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Same guard as SegmentDelegate: data callbacks queued before a cancel landed must not
        // be written past a failed span — the resume-by-file-size logic would count the hole.
        guard earlyError == nil else { return }
        do {
            try handle?.write(contentsOf: data)
        } catch {                       // disk full / IO error — surface it, don't loop 6 silent retries
            earlyError = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        let cumulative = base + received
        if cumulative - lastReported >= 4_000_000 {   // throttle UI updates to ~every 4 MB
            lastReported = cumulative
            onFileBytes(cumulative)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Same crash-ordering as SegmentDelegate: the resume offset here is the .part's FILE
        // SIZE, and APFS can commit the size metadata before the cached data pages — a power
        // loss would then leave a zero-filled tail the next attempt counts as downloaded.
        // One fsync per attempt (before the size becomes authoritative) closes that.
        if received > 0 { try? handle?.synchronize() }
        try? handle?.close()
        handle = nil
        if let earlyError {
            continuation?.resume(throwing: earlyError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            onFileBytes(base + received)   // final tick
            continuation?.resume(returning: ())
        }
        continuation = nil
    }

    /// Same token-hygiene as SegmentDelegate: never let the HuggingFace Bearer header follow
    /// a redirect off the original host (huggingface.co → CDN).
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var req = request
        if let origHost = task.originalRequest?.url?.host?.lowercased(),
           req.url?.host?.lowercased() != origHost {
            req.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(req)
    }

    private func openHandle(truncate: Bool) {
        let fm = FileManager.default
        if truncate || !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: partURL)
        if truncate {
            try? handle?.truncate(atOffset: 0)
        } else {
            _ = try? handle?.seekToEnd()
        }
    }

    /// Start byte of a "Content-Range: bytes START-END/TOTAL" header (-1 if absent/unparseable).
    private static func contentRangeStart(_ header: String?) -> Int64 {
        guard let header, let r = header.range(of: "bytes ") else { return -1 }
        let rest = header[r.upperBound...]
        guard let dash = rest.firstIndex(of: "-") else { return -1 }
        return Int64(rest[rest.startIndex..<dash].trimmingCharacters(in: .whitespaces)) ?? -1
    }
}
