import Foundation
@testable import SkitKit
@_exported import SkitTestSupport

/// A recorded /v0 response (see `Fixtures` in SkitTestSupport).
func fixture(_ name: String) throws -> Data { try Fixtures.data(name) }

func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    do {
        return try JSONDecoder.skit().decode(T.self, from: try fixture(name))
    } catch let error as DecodingError {
        throw SkitError.undecodable(path: name, detail: SkitClient.describe(error))
    }
}
