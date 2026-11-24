import Foundation

/// Every path this app calls on the server, in one place.
///
/// The probe used to build `/v1/health` inline while the receiver served only
/// `/health`, so "Test connection" called a working server dead. The route table
/// itself was the bug: each side kept its own private list, and nothing compared
/// them. `contract/routes.json` is the shared half; `scripts/check-route-drift.py`
/// compares this enum against it and against real server answers.
public enum ApiRoute {
    /// Read-only probe behind "Test connection".
    public static let healthProbe = "/v1/health"
    /// Batch ingest of accepted measurements.
    public static let measurements = "/v1/measurements"

    public static let all: [String] = [healthProbe, measurements]

    /// `URL.appendingPathComponent` treats a leading slash as a path separator and
    /// produces `//v1/...`, which some proxies normalise and some do not.
    public static func relative(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
}
