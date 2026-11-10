import Foundation
@testable import SkitKit
@_exported import SkitTestSupport

/// The recorded /v0 responses: `SKIT_FIXTURES` when set (CI records them from
/// the engine it just built), else the copies checked in beside the tests.
func fixture(_ name: String) throws -> Data {
    let directory: URL
    if let override = ProcessInfo.processInfo.environment["SKIT_FIXTURES"], !override.isEmpty {
        directory = URL(fileURLWithPath: override)
    } else {
        directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }
    return try Data(contentsOf: directory.appendingPathComponent(name))
}

func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    do {
        return try JSONDecoder.skit().decode(T.self, from: try fixture(name))
    } catch let error as DecodingError {
        throw SkitError.undecodable(path: name, detail: SkitClient.describe(error))
    }
}
