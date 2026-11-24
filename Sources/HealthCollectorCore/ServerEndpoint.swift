import Foundation

/// A saved endpoint that has been checked, or the reason it cannot be used.
///
/// The app used to answer "the saved endpoint is empty or malformed" with a
/// compiled-in production address. A typo therefore did not fail — it sent the
/// owner's measurements to a host they never chose, and the only way to notice
/// was to read the source. There is no fallback here: an endpoint is either
/// usable or the caller is told why it is not, and nothing is sent.
public enum EndpointError: Error, Equatable, CustomStringConvertible {
    case empty
    case malformed(String)
    case unsupportedScheme(String)
    case missingHost
    case insecureTransport(String)

    public var description: String {
        switch self {
        case .empty:
            return "no endpoint configured"
        case .malformed(let raw):
            return "not a valid URL: \(raw)"
        case .unsupportedScheme(let scheme):
            return "unsupported scheme \(scheme) — use https"
        case .missingHost:
            return "no host in the address"
        case .insecureTransport(let host):
            return "https required for \(host) — plain http is accepted only for loopback"
        }
    }
}

/// The one place that decides whether a typed address may be used.
public struct ServerEndpoint: Equatable {
    public let url: URL
    public let host: String

    public static func parse(_ raw: String) -> Result<ServerEndpoint, EndpointError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty,
              trimmed.contains("://")
        else { return .failure(.malformed(trimmed)) }

        let lowered = scheme.lowercased()
        guard lowered == "https" || lowered == "http" else {
            return .failure(.unsupportedScheme(scheme))
        }

        guard let host = components.host, !host.isEmpty else {
            return .failure(.missingHost)
        }

        // Measurements are health data: cleartext is refused except on the same
        // device, where there is no network to be read from.
        guard lowered == "https" || isLoopback(host) else {
            return .failure(.insecureTransport(host))
        }
        guard let url = components.url else { return .failure(.malformed(trimmed)) }

        return .success(ServerEndpoint(url: url, host: host))
    }

    static func isLoopback(_ host: String) -> Bool {
        switch host.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]": return true
        default: return false
        }
    }
}
