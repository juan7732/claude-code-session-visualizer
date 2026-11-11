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
                Text(store.locator.trustsOnlyItsHelper && store.locator.bundledHelper != nil
                    ? "SessionVisualizer reads sessions through skit, its engine. The one inside this copy of the app cannot be run; install the app again."
                    : "SessionVisualizer reads sessions through skit, its engine. Install it, or set SKIT_BIN to where it is.")
                    .foregroundStyle(palette.muted)
                Text(lookedIn.map(Format.homeRelative).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).textSelection(.enabled)
                retry
            case .incompatible(let version, let missing):
                Text("skit is too old for this app").font(.display(20))
                Text("The running skit (\(version)) does not serve:").foregroundStyle(palette.muted)
                Text(missing.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                remedy
                retry
            case .unreadable(let version, let detail):
                Text("skit and this app do not match").font(.display(20))
                Text("The running skit (\(version)) answered with something this app cannot read:").foregroundStyle(palette.muted)
                Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                remedy
                retry
            case .misplaced(let place):
                Text("Move SessionVisualizer to Applications").font(.display(20))
                Text(AppStore.moveAdvice(place)).foregroundStyle(palette.muted)
                Text("Nothing is archiving your sessions yet: no background agent is running, and one installed from here would stop working when this copy goes away.")
                    .foregroundStyle(palette.muted)
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

    /// What brings a running engine and this app together: the agent restarted with the app's own `skit`.
    @ViewBuilder private var remedy: some View {
        if let mismatch = store.versionMismatch {
            Text("This app carries skit \(mismatch.bundled).").foregroundStyle(palette.muted)
        }
        if let place = store.installRefusal {
            Text(AppStore.moveAdvice(place)).foregroundStyle(palette.muted)
        } else if let binary = store.locator.findBinary(), store.managesEngine {
            Text("The background agent is running another build of skit. Restarting it with \(Format.homeRelative(binary)) may be all it needs.")
                .foregroundStyle(palette.muted)
            Button("Restart the Background Agent") { Task { await store.restartAgent() } }
                .buttonStyle(.borderedProminent).padding(.top, 6)
        } else {
            Text("Update skit, then run “skit service install” so the background agent restarts with it.").foregroundStyle(palette.muted)
        }
    }

    private var retry: some View {
        Button("Try Again") { Task { await store.connect() } }.padding(.top, 6)
    }
}
