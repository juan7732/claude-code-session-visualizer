import SkitKit
import SwiftUI

/// What the window shows while the engine is not there to talk to, and what to do about it.
struct EngineStateView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            switch store.engine {
            case .connecting, .ready:
                ProgressView().controlSize(.small)
                Text("Looking for skit").foregroundStyle(palette.muted)
            case .starting(let binary):
                ProgressView().controlSize(.small)
                Text("Starting the archiver").font(.display(20))
                Text("Installing the background agent for \(Format.homeRelative(binary)). It keeps your sessions archived from now on.")
                    .foregroundStyle(palette.muted)
            case .missing(let lookedIn):
                Text("skit is not installed").font(.display(20))
                Text("SessionVisualizer reads sessions through skit, its engine. Install it, or set SKIT_BIN to where it is.")
                    .foregroundStyle(palette.muted)
                Text(lookedIn.map(Format.homeRelative).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).textSelection(.enabled)
                retry
            case .incompatible(let version, let missing):
                Text("skit is too old for this app").font(.display(20))
                Text("The running skit (\(version)) does not serve:").foregroundStyle(palette.muted)
                Text(missing.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("Update skit, then run “skit service install” so the background agent restarts with it.").foregroundStyle(palette.muted)
                retry
            case .failed(let why):
                Text("Cannot reach skit").font(.display(20))
                Text(why).foregroundStyle(palette.muted).textSelection(.enabled)
                retry
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
    }

    private var retry: some View {
        Button("Try Again") { Task { await store.connect() } }.padding(.top, 6)
    }
}
