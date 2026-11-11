import AppKit
import SkitKit
import SwiftUI

/// `SKIT_EXERCISE=summary:<session id>` (or `transcript:<id>`, `search:<words>`)
/// in the environment: the real window opens that page, scrolls it from top
/// to bottom by itself and quits. For reproducing a freeze that only a live window shows; the
/// process can be sampled from outside while it runs.
///
/// DECISION: debug builds only. Left in the app that ships, a variable in the environment could
/// drive a person's window and quit it. `just client-exercise` and `Scripts/exercise.sh` run the
/// debug build, so they are as they were.
enum Exercise {
    static func run(_ window: WindowState, _ store: AppStore) async {
        #if DEBUG
        guard let spec = ProcessInfo.processInfo.environment["SKIT_EXERCISE"], let colon = spec.firstIndex(of: ":") else { return }
        let what = String(spec[..<colon]), id = String(spec[spec.index(after: colon)...])
        if what == "search" {
            // search:<words>: the Search page with every session's hits shown.
            window.search.query = id
            window.page = .search
            for _ in 0..<100 where window.search.searched.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            window.search.setAllFolded(false)
        } else if what == "stats" {
            window.page = .stats
            for _ in 0..<100 where store.overviews[""] == nil || store.overviews[""] == .loading { try? await Task.sleep(for: .milliseconds(100)) }
        } else if what == "claude" {
            // claude:<tab>, e.g. claude:flags, the longest list.
            window.claude.tab = ClaudeTab(rawValue: id) ?? .experiments
            window.page = .claude
            for _ in 0..<100 where store.claude == nil || store.claude == .loading { try? await Task.sleep(for: .milliseconds(100)) }
        } else if what == "primitives" {
            // primitives:<kind>, e.g. primitives:memory, the longest list; each item is opened in turn.
            window.primitives.kind = id.isEmpty ? "skill" : id
            window.page = .primitives
            for _ in 0..<100 where store.primitives[0] == nil || store.primitives[0] == .loading { try? await Task.sleep(for: .milliseconds(100)) }
            if case .loaded(let report) = store.primitives[0] {
                for item in report.items.filter({ $0.kind == window.primitives.kind }).prefix(12) {
                    window.primitives.selected[item.kind] = item.name
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } else if what == "host" {
            // host:<session id>: what a card's "Open in VS Code" does, for a running session, and nothing else.
            window.page = .now
            store.nowMinutes = 1440
            await store.loadNow()
            let host = store.nowSession(id)?.host
            let opened = host.map { HostOpener.open($0) } ?? false
            FileHandle.standardError.write(Data("scroll-through: host of \(id): \(host.map { HostContent.title($0) + " → " + (HostContent.target($0) ?? "the application") } ?? "none") opened=\(opened)\n".utf8))
            try? await Task.sleep(for: .milliseconds(1500))
            exit(0)
        } else if what == "now" {
            // now:<minutes>, e.g. now:1440 for every session of the last day.
            store.nowMinutes = Int(id) ?? 60
            window.page = .now
            for _ in 0..<100 where store.now == nil || store.now == .loading { try? await Task.sleep(for: .milliseconds(100)) }
        } else if what == "compare" {
            window.showCompare(in: store)
        } else if what == "images" {
            // images:<session id>: the Files view on its Images grid.
            window.open(session: id, view: .files)
            window.files.tab = .images
            for _ in 0..<200 where store.model(id) == nil { try? await Task.sleep(for: .milliseconds(100)) }
        } else if let view = SessionView(rawValue: what) {
            window.open(session: id, view: view)
            for _ in 0..<200 where store.model(id) == nil { try? await Task.sleep(for: .milliseconds(100)) }
        } else {
            return
        }
        try? await Task.sleep(for: .milliseconds(1500))
        FileHandle.standardError.write(Data("exercise: \(what) of \(id) is up\n".utf8))
        if let shown = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) { await Snapshot.scrollThrough(shown) }
        if what == "canvas" {
            // The canvas has no scroll view: the camera pans through it, a notch a frame, then zooms out and back.
            for _ in 0..<100 where window.canvas.cameraFor == nil { try? await Task.sleep(for: .milliseconds(50)) }
            let sideways = window.canvas.score
            for tick in 0..<240 {
                if tick < 160 {
                    if sideways { window.canvas.camera.x -= 45 } else { window.canvas.camera.y -= 45 }
                } else {
                    window.canvas.zoom(by: tick < 200 ? 0.95 : 1 / 0.95)
                }
                if tick % 8 == 0 { FileHandle.standardError.write(Data("scroll-through: camera \(tick) of 240\n".utf8)) }
                try? await Task.sleep(for: .milliseconds(16))
            }
            FileHandle.standardError.write(Data("scroll-through: panned and zoomed the \(sideways ? "Score" : "Braid")\n".utf8))
        }
        if what == "timeline" {
            // Then the playhead plays for a few seconds with the ledger following it.
            window.timeline.playing = true
            for tick in 0..<80 {
                try? await Task.sleep(for: .milliseconds(50))
                if tick % 4 == 0 {
                    FileHandle.standardError.write(Data("scroll-through: playing, \(tick) of 80, action \(window.timeline.current ?? -1)\n".utf8))
                }
            }
            window.timeline.playing = false
            FileHandle.standardError.write(Data("scroll-through: played to action \(window.timeline.current ?? -1)\n".utf8))
        }
        try? await Task.sleep(for: .milliseconds(500))
        exit(0)
        #endif
    }
}
