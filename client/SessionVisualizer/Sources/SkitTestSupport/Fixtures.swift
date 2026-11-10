import Foundation

/// The recorded /v0 responses of the engine serving the `synthetic-basics`
/// fixture (`Scripts/record-fixtures.sh`). `SKIT_FIXTURES` points the tests at
/// another recording: CI makes one from the engine in the commit under test.
public enum Fixtures {
    public static func data(_ name: String) throws -> Data {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["SKIT_FIXTURES"], !override.isEmpty {
            directory = URL(fileURLWithPath: override)
        } else {
            directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        }
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }
}
