import Foundation

/// Streams a response via `session.bytes(for:)` instead of `session.data(for:)`,
/// so a hostile or misbehaving server can't force unbounded buffering — mirrors
/// the pattern already used by `WorkshopPreviewImageLoader.fetchData`.
enum BoundedNetworkFetch {
    struct ResponseTooLarge: Error, Equatable, Sendable {
        let byteCap: Int
    }

    /// Bytes staged in a plain array before each `Data.append`. `AsyncBytes`
    /// only vends one byte at a time, and appending each of a 2 MB preview's
    /// bytes straight onto `Data` was the single hottest thing on the cooperative
    /// pool while a Workshop page scrolled.
    private static let chunkSize = 64 * 1024

    /// Rejects by declared `Content-Length` before reading any body, then aborts
    /// mid-stream the moment accumulated bytes exceed `byteCap` — never buffers
    /// more than `byteCap` bytes regardless of what the server claims or sends.
    static func fetch(
        _ request: URLRequest,
        session: URLSession,
        byteCap: Int
    ) async throws -> (data: Data, response: URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        if let http, http.expectedContentLength > Int64(byteCap) {
            throw ResponseTooLarge(byteCap: byteCap)
        }
        let data = try await collect(
            bytes,
            expectedContentLength: http?.expectedContentLength ?? -1,
            byteCap: byteCap
        )
        return (data, response)
    }

    /// Drains an already-validated body, enforcing `byteCap` as it goes.
    static func collect(
        _ bytes: URLSession.AsyncBytes,
        expectedContentLength: Int64,
        byteCap: Int
    ) async throws -> Data {
        var data = Data()
        if expectedContentLength > 0, expectedContentLength <= Int64(byteCap) {
            data.reserveCapacity(Int(expectedContentLength))
        }
        var chunk = [UInt8]()
        chunk.reserveCapacity(chunkSize)
        var total = 0
        for try await byte in bytes {
            chunk.append(byte)
            total += 1
            if total > byteCap {
                throw ResponseTooLarge(byteCap: byteCap)
            }
            if chunk.count == chunkSize {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            data.append(contentsOf: chunk)
        }
        return data
    }
}
