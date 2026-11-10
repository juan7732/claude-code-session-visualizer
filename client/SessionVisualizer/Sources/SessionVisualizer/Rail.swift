import SkitKit
import SwiftUI

/// The icon rail: the app's areas, with a flyout on Sessions that carries
/// projects, what is live and what was recent (NOTES, iteration 11).
struct Rail: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @Environment(\.openSettings) private var openSettings
    @State private var overItem = false
    @State private var overFlyout = false
    @State private var flyoutShown = false
    @Environment(\.snapshotFlyout) private var snapshotFlyout

    var body: some View {
        VStack(spacing: 4) {
            RailItem(symbol: "rectangle.stack", label: "Sessions", active: isSessions, badge: store.liveCount) {
                window.page = .sessions
            }
            .onHover { overItem = $0; settleFlyout() }
            .overlay(alignment: .topLeading) {
                if flyoutShown || snapshotFlyout {
                    SessionsFlyout { flyoutShown = false }
                        .onHover { overFlyout = $0; settleFlyout() }
                        .offset(x: 52, y: -6)
                        .transition(.opacity)
                }
            }
            RailItem(symbol: "magnifyingglass", label: "Search", active: window.page == .search) { window.page = .search }
            RailItem(symbol: "chart.bar", label: "Stats", active: window.page == .stats) { window.page = .stats }
            RailItem(symbol: "asterisk", label: "Claude", active: window.page == .claude) { window.page = .claude }
            Spacer()
            RailItem(symbol: "gearshape", label: "Settings", active: false) { openSettings() }
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(width: Metric.railWidth)
        .frame(maxHeight: .infinity)
        .background(palette.panel2)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.line).frame(width: 1) }
    }

    private var isSessions: Bool {
        if case .session = window.page { return true }
        return window.page == .sessions
    }

    /// The flyout stays while the pointer is on the item or on the flyout, and
    /// leaves a moment after both are left, so the gap between them is crossable.
    private func settleFlyout() {
        if overItem || overFlyout {
            withAnimation(.easeOut(duration: 0.12)) { flyoutShown = true }
        } else {
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                if !overItem && !overFlyout { withAnimation(.easeOut(duration: 0.12)) { flyoutShown = false } }
            }
        }
    }
}

private struct RailItem: View {
    @Environment(\.palette) private var palette
    var symbol: String
    var label: String
    var active: Bool
    var badge = 0
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(height: 20)
                Text(label).font(.label(9.5)).tracking(0.2)
            }
            .foregroundStyle(active ? palette.accent : palette.muted)
            .frame(width: 48, height: 46)
            .background {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                    .fill(active ? palette.panel : (hover ? palette.line : .clear))
                    .shadow(color: active ? palette.shadow.opacity(0.5) : .clear, radius: 6, y: 3)
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 9, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 13, minHeight: 13)
                        .background(palette.ok, in: Capsule()).offset(x: -3, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(badge > 0 ? "\(label), \(badge) live" : label)
    }
}

/// Projects, live sessions and the five most recent, one click from anywhere.
private struct SessionsFlyout: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var dismiss: () -> Void

    var body: some View {
        let live = store.sessions.filter { store.isLive($0.id) }
        let recent = store.sessions.filter { !store.isLive($0.id) }.sorted { $0.lastAt > $1.lastAt }.prefix(5)
        VStack(alignment: .leading, spacing: 0) {
            group("Projects")
            ForEach(window.projects(in: store), id: \.cwd) { project in
                row(Format.projectName(cwd: project.cwd, slug: nil), trailing: "\(project.count)", symbol: "rectangle.stack",
                    active: window.filterProject == project.cwd) {
                    window.filterProject = project.cwd
                    window.page = .sessions
                }
                .help(project.cwd)
            }
            group("Live now")
            if live.isEmpty {
                Text("none").font(.system(size: 12.5)).foregroundStyle(palette.muted).padding(.horizontal, 9).padding(.vertical, 6)
            }
            ForEach(live) { session in
                row(session.title, trailing: nil, dot: true, active: window.sessionID == session.id) { window.page = .session(session.id) }
            }
            group("Recent")
            ForEach(recent) { session in
                row(session.title, trailing: Format.ago(session.lastAt), active: window.sessionID == session.id) { window.page = .session(session.id) }
            }
        }
        .padding(8)
        .frame(width: 260, alignment: .leading)
        .background { Panel(shadow: palette.shadow, radius: 15, y: 10) }
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private func row(_ title: String, trailing: String?, symbol: String? = nil, dot: Bool = false, active: Bool, action: @escaping () -> Void) -> some View {
        FlyoutRow(title: title, trailing: trailing, symbol: symbol, dot: dot, active: active) {
            action()
            dismiss()
        }
    }
}

private struct FlyoutRow: View {
    @Environment(\.palette) private var palette
    var title: String
    var trailing: String?
    var symbol: String?
    var dot: Bool
    var active: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(palette.ink2).frame(width: 14) }
                if dot { Circle().fill(palette.ok).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(palette.muted) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(active ? palette.accentSoft : (hover ? palette.line : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
