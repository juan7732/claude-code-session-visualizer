import SkitKit
import SwiftUI

/// One session: its views over one selection, and the drawer under them.
/// The Summary, the Transcript and the Canvas are built; the other views name
/// the milestone that brings them.
struct SessionPage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.inspector) private var inspector = true
    var id: String

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let session = store.session(id) {
                    switch window.sessionView {
                    case .summary: SummaryView(session: session)
                    case .transcript: transcript
                    case .canvas: canvas
                    default: ComingPage(title: window.sessionView.title, milestone: window.sessionView.arrives ?? "")
                    }
                } else {
                    ComingPage(title: "No session \(Format.shortID(id))", detail: "It is neither on disk nor in the archive.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if inspector, window.sessionView.arrives == nil, let key = window.selection, let model = store.model(id) {
                Drawer(model: model, key: key).transition(.move(edge: .bottom))
            }
        }
        .animation(.easeOut(duration: 0.15), value: window.selection == nil)
        .task(id: id) { await store.loadStats(id) }
        .task(id: id) {
            await store.loadModel(id)
            if let model = store.model(id) { window.applyPending(in: model) }
        }
        .onChange(of: window.pending) {
            // A link to a node of the session that is already open.
            if let model = store.model(id) { window.applyPending(in: model) }
        }
    }

    @ViewBuilder private var canvas: some View {
        switch store.models[id] {
        case .loaded(let model):
            if model.items.isEmpty {
                ComingPage(title: "Nothing was said", detail: "This session has no prompts and no requests.")
            } else {
                CanvasView(model: model)
            }
        case .failed(let why):
            ComingPage(title: "Could not read the session", detail: why)
        case .loading, nil:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the session").foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.bg)
        }
    }

    @ViewBuilder private var transcript: some View {
        switch store.models[id] {
        case .loaded(let model):
            if model.items.isEmpty {
                ComingPage(title: "Nothing was said", detail: "This session has no prompts and no requests.")
            } else {
                TranscriptView(model: model)
            }
        case .failed(let why):
            ComingPage(title: "Could not read the session", detail: why)
        case .loading, nil:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the session").foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.bg)
        }
    }
}

/// Label and value pairs, as in the mock's cards.
struct Facts: View {
    @Environment(\.palette) private var palette
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(palette.muted)
                    Text(row.1).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// A page or view that a later milestone brings.
struct ComingPage: View {
    @Environment(\.palette) private var palette
    var title: String
    var milestone = ""
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.display(22))
            Text(detail ?? "Not built yet. It arrives with \(milestone) of the plan.").foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
    }
}
