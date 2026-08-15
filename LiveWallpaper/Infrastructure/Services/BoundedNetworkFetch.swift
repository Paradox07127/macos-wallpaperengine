import Foundation

/// Streams a response via `session.bytes(for:)` instead of `session.data(for:)`,
/// so a hostile or misbehaving server can't force unbounded buffering — mirrors
/// the pattern already used by `WorkshopPreviewImageLoader.fetchData`.
enum BoundedNetworkFetch {
    struct ResponseTooLarge: Error, Equatable, Sendable {
        let byteCap: Int
    }

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
        var data = Data()
        if let http, http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > byteCap {
                throw ResponseTooLarge(byteCap: byteCap)
            }
        }
        return (data, response)
    }
}
