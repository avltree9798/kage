#if canImport(WebKit)
import Foundation
import Observation
import WebKit
import KageModels
import Persistence

/// Spec 6.7: WebKit downloads with progress, cancel, retry and resume where the server allows.
@MainActor @Observable
public final class DownloadManager: NSObject {
    public struct Item: Identifiable, Sendable {
        public var record: DownloadRecord
        public var destination: URL?
        public var error: String?
        public var canResume: Bool
        public var isRisky: Bool { FilenameSanitizer.isRisky(record.filename) }
        public var id: UUID { record.id }
    }

    public private(set) var items: [Item] = []
    public var activeCount: Int { items.filter { $0.record.status == .inProgress }.count }

    @ObservationIgnored private var live: [ObjectIdentifier: (id: UUID, download: WKDownload, observation: NSKeyValueObservation)] = [:]
    @ObservationIgnored private var resumeData: [UUID: Data] = [:]
    @ObservationIgnored private let repository: DownloadRepository?
    @ObservationIgnored public var directory: URL
    /// Web view used to resume downloads after relaunch.
    @ObservationIgnored public var resumeHost: (() -> WKWebView?)?

    public init(repository: DownloadRepository?, directory: URL? = nil) {
        self.repository = repository
        let fm = FileManager.default
        self.directory = directory ?? (fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0])
        super.init()
    }

    public func load() async {
        guard let repo = repository, let saved = try? await repo.all() else { return }
        var restored: [Item] = []
        for r in saved {
            var r = r
            // Anything mid-flight when the app quit is now paused; resume only if WebKit gave us data.
            if r.status == .inProgress || r.status == .pending { r.status = .paused }
            let data = try? await repo.resumeData(id: r.id)
            if let data { resumeData[r.id] = data }
            restored.append(Item(record: r, destination: nil, error: nil, canResume: data != nil))
        }
        items = restored
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let url = download.originalRequest?.url ?? URL(string: "about:blank")!
        let record = DownloadRecord(sourceURL: url, filename: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent,
                                    status: .inProgress, progress: 0)
        items.insert(Item(record: record, destination: nil, error: nil, canResume: false), at: 0)
        let obs = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            let rid = record.id
            Task { @MainActor [weak self] in self?.update(rid) { $0.record.progress = fraction } }
        }
        live[ObjectIdentifier(download)] = (record.id, download, obs)
        save(record.id)
    }

    public func cancel(_ id: UUID) {
        guard let entry = live.values.first(where: { $0.id == id }) else { return }
        entry.download.cancel { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data { self.resumeData[id] = data }
                self.update(id) { $0.record.status = .cancelled; $0.canResume = data != nil }
                self.save(id)
            }
        }
    }

    /// Resumes with WebKit resume data if the server supported it, otherwise starts again.
    public func retry(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), let wv = resumeHost?() else { return }
        let new: WKDownload
        if let data = resumeData[id] {
            new = await wv.resumeDownload(fromResumeData: data)
        } else {
            new = await wv.startDownload(using: URLRequest(url: item.record.sourceURL))
        }
        remove(id)
        track(new)
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        resumeData[id] = nil
        Task { try? await repository?.delete(id: id) }
    }

    public func clearFinished() {
        for i in items where i.record.status == .completed || i.record.status == .failed || i.record.status == .cancelled {
            remove(i.id)
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func save(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let data = resumeData[id]
        Task { try? await repository?.save(item.record, resumeData: data) }
    }

    private func id(for download: WKDownload) -> UUID? { live[ObjectIdentifier(download)]?.id }
}

extension DownloadManager: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String) async -> URL? {
        guard let id = id(for: download) else { return nil }
        let name = FilenameSanitizer.sanitize(suggestedFilename)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = FilenameSanitizer.uniqueDestination(for: name, in: directory)
        update(id) {
            $0.record.filename = dest.lastPathComponent
            $0.destination = dest
        }
        save(id)
        return dest
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(for: download) else { return }
        update(id) { $0.record.status = .completed; $0.record.progress = 1 }
        if let dest = items.first(where: { $0.id == id })?.destination,
           let bookmark = try? dest.bookmarkData() {
            update(id) { $0.record.destinationBookmark = bookmark }
        }
        resumeData[id] = nil
        live[ObjectIdentifier(download)] = nil
        save(id)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = id(for: download) else { return }
        if let resumeData { self.resumeData[id] = resumeData }
        update(id) {
            $0.record.status = .failed
            $0.error = error.localizedDescription
            $0.canResume = resumeData != nil
        }
        live[ObjectIdentifier(download)] = nil
        save(id)
    }
}
#endif
