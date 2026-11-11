import SwiftUI

/// Bento, the one visual style (plan, M7): neutral greys, one accent, rounded
/// blocks, soft shadows. The values are the mock's (`ux-mocks/app.css`,
/// `[data-style="bento"]`). Light and dark follow the system; pure black for
/// OLED displays is a setting that applies in dark mode.
struct Palette: Hashable {
    var bg, panel, panel2: Color
    var ink, ink2, muted, muted2: Color
    var line, line2: Color
    var accent, accentSoft: Color
    var warn, err, ok, tool: Color
    /// Outside services and connectors; injected context and control calls.
    var plug, ctx: Color
    var shadow: Color

    /// The colour a tool call is drawn in, by what it is for.
    func color(_ family: ToolFamily) -> Color {
        switch family {
        case .shell: tool
        case .file: ink2
        case .web, .connector: plug
        case .agent: warn
        case .skill: accent
        case .control: ctx
        case .other: muted
        }
    }

    static let light = Palette(
        bg: Color(hex: 0xEEEEF0), panel: Color(hex: 0xFFFFFF), panel2: Color(hex: 0xE4E4E8),
        ink: Color(hex: 0x17171A), ink2: Color(hex: 0x4A4A52), muted: Color(hex: 0x80808A), muted2: Color(hex: 0xB0B0B8),
        line: .black.opacity(0.06), line2: .black.opacity(0.12),
        accent: Color(hex: 0x5B5BD6), accentSoft: Color(hex: 0x5B5BD6).opacity(0.12),
        warn: Color(hex: 0xD98A00), err: Color(hex: 0xD9485F), ok: Color(hex: 0x2F9E6F), tool: Color(hex: 0x2F9E6F),
        plug: Color(hex: 0xC2419A), ctx: Color(hex: 0xA0A0A8),
        shadow: Color(hex: 0x17171A).opacity(0.18))

    static let dark = Palette(
        bg: Color(hex: 0x121214), panel: Color(hex: 0x1C1C20), panel2: Color(hex: 0x26262C),
        ink: Color(hex: 0xF2F2F5), ink2: Color(hex: 0xC9C9D1), muted: Color(hex: 0x8C8C96), muted2: Color(hex: 0x55555E),
        line: .white.opacity(0.07), line2: .white.opacity(0.14),
        accent: Color(hex: 0x8B8BFF), accentSoft: Color(hex: 0x8B8BFF).opacity(0.18),
        warn: Color(hex: 0xD98A00), err: Color(hex: 0xD9485F), ok: Color(hex: 0x2F9E6F), tool: Color(hex: 0x4FD1A0),
        plug: Color(hex: 0xC2419A), ctx: Color(hex: 0xA0A0A8),
        shadow: .black.opacity(0.5))

    static let oled = Palette(
        bg: Color(hex: 0x000000), panel: Color(hex: 0x0B0B0D), panel2: Color(hex: 0x141418),
        ink: Color(hex: 0xF4F4F7), ink2: Color(hex: 0xC6C6CF), muted: Color(hex: 0x8C8C94), muted2: Color(hex: 0x55555C),
        line: .white.opacity(0.09), line2: .white.opacity(0.22),
        accent: Color(hex: 0x9B9BFF), accentSoft: Color(hex: 0x9B9BFF).opacity(0.18),
        warn: Color(hex: 0xFFB340), err: Color(hex: 0xFF6B7A), ok: Color(hex: 0x2F9E6F), tool: Color(hex: 0x5FE0B0),
        plug: Color(hex: 0xC2419A), ctx: Color(hex: 0xA0A0A8),
        shadow: .black.opacity(0.7))

    static func resolve(_ scheme: ColorScheme, oled: Bool) -> Palette {
        scheme == .dark ? (oled ? .oled : .dark) : .light
    }
}

/// Sizes and type shared by every view.
enum Metric {
    /// Corner radius of cards, rows and controls.
    static let radius: CGFloat = 14
    static let railWidth: CGFloat = 60
    /// Reading column of the home page and width of the summary.
    static let column: CGFloat = 860
    static let wideColumn: CGFloat = 1180
}

extension Font {
    /// Titles: Avenir Next bold, as the mock's display face.
    static func display(_ size: CGFloat) -> Font { .custom("Avenir Next", size: size).weight(.bold) }
    /// Small capitals above cards and on the date stamp.
    static let caps = Font.custom("Avenir Next", size: 10.5).weight(.semibold)
    /// Secondary lines in Avenir Next (times, counts).
    static func label(_ size: CGFloat = 11.5) -> Font { .custom("Avenir Next", size: size) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Resolves the palette from the system's appearance and the OLED setting and
/// hands it to everything below.
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(SettingsKey.oled) private var oled = false
    @ViewBuilder var content: Content

    var body: some View {
        let palette = Palette.resolve(scheme, oled: oled)
        content
            .environment(\.palette, palette)
            .tint(palette.accent)
            .foregroundStyle(palette.ink)
            .webLinksOnly()
    }
}

extension View {
    /// A link clicked in any text below opens only when it is to the web (`LinkPolicy`). `InlineText`
    /// already takes other destinations out of what it draws; this is the same rule at the root of a
    /// window, for text that reaches the screen some other way. The app's own `skit-visualizer://`
    /// links arrive through `onOpenURL`, which this does not touch.
    func webLinksOnly() -> some View {
        environment(\.openURL, OpenURLAction { LinkPolicy.opens($0) ? .systemAction : .discarded })
    }
}

/// A Bento card: panel background, rounded, soft shadow, an optional caps heading.
struct Card<Content: View>: View {
    @Environment(\.palette) private var palette
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            }
            content
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 9, y: 6) }
    }
}

/// The rounded panel behind cards, the flyout and notices. The shadow belongs
/// to the panel alone: put on the whole view, it would fall from every glyph too.
struct Panel: View {
    @Environment(\.palette) private var palette
    var shadow: Color
    var radius: CGFloat
    var y: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
            .fill(palette.panel)
            .shadow(color: shadow, radius: radius, y: y)
    }
}

enum SettingsKey {
    static let oled = "appearance.oled"
    static let sidebar = "shell.sidebar"
    static let sessionSort = "sessions.sort"
    static let inspector = "shell.inspector"
    static let inspectorHeight = "shell.inspectorHeight"
    static let compactTools = "transcript.compactTools"
    static let showThinking = "transcript.showThinking"
    static let scrollMap = "transcript.scrollMap"
    static let keyHint = "transcript.keyHint"
    static let foldByDefault = "transcript.foldByDefault"
    static let summaryDigest = "summary.digest"
    static let summaryHours = "summary.hours"
    static let summaryMap = "summary.map"
    /// The context window the Summary's gauge measures against, in tokens.
    static let contextWindow = "summary.contextWindow"
    /// Recent searches, one per line, newest first.
    static let recentSearches = "search.recent"
    /// Whether searches are remembered at all (on unless turned off in Settings).
    static let keepRecentSearches = "search.keepRecent"
    /// A search that finds several sessions starts with each folded to one line.
    static let searchFolded = "search.folded"
    static let canvasBackground = "canvas.background"
    static let canvasMinimap = "canvas.minimap"
    static let canvasLegend = "canvas.legend"
    static let canvasNotes = "canvas.resultNotes"
    /// How fast the Timeline's playhead plays, in points of the strip a second.
    static let timelineSpeed = "timeline.speed"
    /// The ledger scrolls to the playhead as it plays or is dragged.
    static let timelineFollow = "timeline.follow"
    /// What "Open" on a file opens it in: an application's bundle id or its path; empty for each file's default app.
    static let fileOpener = "files.opener"
    /// Sessions the person asked to be reminded about before their prompt cache expires, and how many minutes before.
    static let nowReminders = "now.reminders"
    static let nowReminderMinutes = "now.reminderMinutes"
    /// "braid" (reading order) or "score" (time-true staves).
    static let canvasLayout = "canvas.layout"
    /// The Score's time scale, in canvas points a second, and whether files that kept coming back have rows.
    static let scoreScale = "canvas.score.scale"
    static let scoreFiles = "canvas.score.files"
    /// Where a session's canvas was left: one camera per session and layout.
    static func canvasCamera(_ sessionID: String, score: Bool = false) -> String { (score ? canvasCameraScorePrefix : canvasCameraPrefix) + sessionID }
    nonisolated static let canvasCameraPrefix = "canvas.camera."
    nonisolated static let canvasCameraScorePrefix = "canvas.camera.score."
}

/// The searches that led somewhere, kept in the defaults as one line each, newest first.
/// They are words about the person's own work, in a file any process of theirs can read: keeping
/// them is a setting, and they can be cleared.
enum RecentSearches {
    static let limit = 6

    /// The list with `query` put first. Nothing is added while searches are not kept, and what was kept before goes.
    static func adding(_ query: String, to recent: String, keeping: Bool) -> String {
        guard keeping else { return "" }
        guard query.count >= 2 else { return recent }
        let past = recent.split(separator: "\n").map(String.init).filter { $0 != query }
        return ([query] + past).prefix(limit).joined(separator: "\n")
    }
}

/// Where canvases were left: one key per session and layout, which would otherwise stay for every session ever opened.
enum CanvasMemory {
    /// The camera keys among `keys` that belong to no session in `ids`.
    static func stale(_ keys: some Sequence<String>, keeping ids: Set<String>) -> [String] {
        keys.filter { key in
            guard key.hasPrefix(SettingsKey.canvasCameraPrefix) else { return false }
            let prefix = key.hasPrefix(SettingsKey.canvasCameraScorePrefix) ? SettingsKey.canvasCameraScorePrefix : SettingsKey.canvasCameraPrefix
            return !ids.contains(String(key.dropFirst(prefix.count)))
        }
    }

    /// Forgets the cameras of sessions the engine no longer lists. With no session listed nothing is
    /// forgotten: an empty list is more likely an engine that has not looked yet than an empty Mac.
    static func prune(keeping ids: Set<String>, in defaults: UserDefaults = .standard) {
        guard !ids.isEmpty else { return }
        for key in stale(defaults.dictionaryRepresentation().keys, keeping: ids) { defaults.removeObject(forKey: key) }
    }
}
