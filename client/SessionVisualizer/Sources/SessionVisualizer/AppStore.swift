import Foundation
import Observation
import SkitKit

/// Whether the engine is there to talk to.
enum EngineState: Equatable {
    case connecting
    /// Installing or starting the background agent for the `skit` at this path.
    case starting(binary: String)
    case ready
    /// No `skit` anywhere it is looked for.
    case missing(lookedIn: [String])
    /// An engine answers, but it lacks routes this app calls.
    case incompatible(version: String, missing: [String])
    case failed(String)
}

/// A value that is loaded on demand.
enum Loadable<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case failed(String)
}

/// What every window shares: the engine connection, the sessions, what the
/// human added to them. One per process.
@Observable
final class AppStore {
    let locator: EngineLocator
    let client: SkitClient
    /// When false the app only attaches to an engine that is already serving:
    /// it never installs the agent (snapshots, tests).
    let managesEngine: Bool

    private(set) var engine: EngineState = .connecting
    private(set) var status: EngineStatus?
    private(set) var sessions: [SessionSummary] = []
    private(set) var annotations: [String: Annotation] = [:]
    private(set) var stats: [String: Loadable<SessionSummary>] = [:]
    /// The last thing that went wrong after the engine was ready (a failed pin, a failed refresh).
    var notice: String?

    init(locator: EngineLocator = EngineLocator(helpersDirectory: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path),
         socketPath: String? = nil, managesEngine: Bool = true) {
        self.locator = locator
        self.client = SkitClient(socketPath: socketPath ?? locator.socketPath)
        self.managesEngine = managesEngine
    }

    // MARK: Engine

    /// Reaches the engine: attach to the one that is serving, else have the
    /// `skit` we can find install its background agent and wait for it.
    func connect() async {
        engine = .connecting
        let connector = EngineConnector(client: client, locator: locator, managesEngine: managesEngine)
        let outcome = await connector.connect { binary in
            await MainActor.run { self.engine = .starting(binary: binary) }
        }
        switch outcome {
        case .ready:
            do {
                try await load()
                engine = .ready
            } catch {
                engine = .failed("\(error)")
            }
        case .missing(let lookedIn): engine = .missing(lookedIn: lookedIn)
        case .incompatible(let version, let missing): engine = .incompatible(version: version, missing: missing)
        case .failed(let why): engine = .failed(why)
        }
    }

    private func load() async throws {
        async let status = client.status()
        async let sessions = client.sessions()
        async let annotations = client.annotations()
        (self.status, self.sessions, self.annotations) = try await (status, sessions, annotations)
    }

    /// Reloads the list while the app is open; sessions keep changing under it.
    func refresh() async {
        guard engine == .ready else { return }
        do {
            try await load()
        } catch SkitError.unreachable {
            await connect()
        } catch {
            notice = "\(error)"
        }
    }

    // MARK: Sessions

    func session(_ id: String) -> SessionSummary? { sessions.first { $0.id == id } }

    func isLive(_ id: String) -> Bool { status?.live.contains { $0.sessionId == id } ?? false }

    var liveCount: Int { sessions.filter { isLive($0.id) }.count }

    func annotation(_ id: String) -> Annotation { annotations[id] ?? Annotation() }

    /// Every tag in use, in alphabetical order.
    var allTags: [String] { Array(Set(annotations.values.flatMap(\.tags))).sorted() }

    func loadStats(_ id: String) async {
        if case .loaded = stats[id] {} else { stats[id] = .loading }
        do {
            stats[id] = .loaded(try await client.stats(session: id))
        } catch {
            stats[id] = .failed("\(error)")
        }
    }

    // MARK: What the human adds

    func togglePin(_ id: String) async {
        await annotate(id, AnnotationPatch(pinned: !annotation(id).pinned))
    }

    func addTag(_ id: String, _ tag: String) async {
        let tag = tag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !tag.isEmpty else { return }
        await annotate(id, AnnotationPatch(addTags: [tag]))
    }

    func removeTag(_ id: String, _ tag: String) async {
        await annotate(id, AnnotationPatch(removeTags: [tag]))
    }

    private func annotate(_ id: String, _ patch: AnnotationPatch) async {
        do {
            annotations[id] = try await client.annotate(session: id, patch)
        } catch {
            notice = "\(error)"
        }
    }

    func archiveNow(_ id: String) async {
        do {
            let results = try await client.archive(ids: [id])
            notice = results.first.map { "Archive: \($0.action), \($0.records) records." }
        } catch {
            notice = "\(error)"
        }
    }
}
