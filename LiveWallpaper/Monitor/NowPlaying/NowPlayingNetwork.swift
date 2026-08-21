import Foundation

/// Origin policy and bounded transport for the Now Playing layer's two fetchers.
///
/// Both talk to a fixed set of third-party endpoints, so every URL that comes
/// *back* from one of them — an oEmbed `thumbnail_url`, an iTunes `artworkUrl100`,
/// a redirect — is untrusted input. It is checked before the request goes out and
/// again against the response URL, which is what catches a redirect.
enum NowPlayingNetwork {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Origin {
        /// The metadata endpoints themselves.
        case api
        /// Cover-art CDNs the metadata endpoints hand us.
        case artwork
    }

    static let apiHosts: Set<String> = ["open.spotify.com", "itunes.apple.com", "lrclib.net"]
    /// Spotify serves covers from `*.scdn.co` / `*.spotifycdn.com`, Apple from `*.mzstatic.com`.
    static let artworkHostSuffixes = ["scdn.co", "spotifycdn.com", "mzstatic.com"]

    static func isAllowed(_ url: URL?, for origin: Origin) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443
        else { return false }
        guard var host = components.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        guard !isIPLiteral(host) else { return false }

        switch origin {
        case .api:
            return apiHosts.contains(host)
        case .artwork:
            return artworkHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
        }
    }

    /// URLComponents strips IPv6 brackets, so a bare literal still has colons.
    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let labels = host.split(separator: ".")
        return labels.count == 4 && labels.allSatisfy { Int($0) != nil }
    }

    /// Streams the body and aborts past `byteCap`, so a server that lies about
    /// (or omits) `Content-Length` cannot force unbounded buffering. Redirects
    /// that leave the allow-list are dropped rather than followed.
    static func boundedTransport(byteCap: Int) -> Transport {
        let session = URLSession(
            configuration: .ephemeral,
            delegate: AllowListRedirectPolicy(),
            delegateQueue: nil
        )
        return { request in
            do {
                return try await BoundedNetworkFetch.fetch(request, session: session, byteCap: byteCap)
            } catch is BoundedNetworkFetch.ResponseTooLarge {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
    }
}

private final class AllowListRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Stateless: every callback only reads the immutable allow-list.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let url = request.url
        let allowed = NowPlayingNetwork.isAllowed(url, for: .api)
            || NowPlayingNetwork.isAllowed(url, for: .artwork)
        completionHandler(allowed ? request : nil)
    }
}
