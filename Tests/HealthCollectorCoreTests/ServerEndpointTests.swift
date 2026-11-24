import XCTest
@testable import HealthCollectorCore

/// Acceptance for P0-3: an endpoint that was not configured, or was typed wrong,
/// must not become an address. Every shape that used to fall back to the
/// compiled-in host is listed here; none of them may parse.
final class ServerEndpointTests: XCTestCase {

    private func failure(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> EndpointError? {
        switch ServerEndpoint.parse(raw) {
        case .success:
            XCTFail("expected \(raw.debugDescription) to be refused", file: file, line: line)
            return nil
        case .failure(let error):
            return error
        }
    }

    func testEmptyEndpointIsNotConfigured() {
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("   "), .empty)
        XCTAssertEqual(failure("\n\t"), .empty)
    }

    func testAddressWithoutSchemeIsRefusedRatherThanGuessed() {
        // What the Settings field actually receives when someone pastes a host.
        XCTAssertEqual(failure("hermes00.duckdns.org:1118"), .malformed("hermes00.duckdns.org:1118"))
        XCTAssertEqual(failure("duckdns.org"), .malformed("duckdns.org"))
    }

    func testMixedCaseAndSpacesStillParse() {
        switch ServerEndpoint.parse("  https://example.org:8443  ") {
        case .success(let endpoint):
            XCTAssertEqual(endpoint.host, "example.org")
            XCTAssertEqual(endpoint.url.port, 8443)
            XCTAssertEqual(endpoint.url.scheme, "https")
        case .failure(let error):
            XCTFail("valid address refused: \(error)")
        }
    }

    func testSchemeMustBeHttpOrHttps() {
        XCTAssertEqual(failure("ftp://example.org"), .unsupportedScheme("ftp"))
        XCTAssertEqual(failure("file:///tmp/x"), .unsupportedScheme("file"))
    }

    func testCleartextIsRefusedOffTheDevice() {
        XCTAssertEqual(failure("http://example.org:8090"), .insecureTransport("example.org"))
        // Loopback stays usable: local testing has no network to leak onto.
        switch ServerEndpoint.parse("http://127.0.0.1:8090") {
        case .success(let endpoint): XCTAssertEqual(endpoint.host, "127.0.0.1")
        case .failure(let error): XCTFail("loopback refused: \(error)")
        }
        switch ServerEndpoint.parse("http://localhost:8090") {
        case .success(let endpoint): XCTAssertEqual(endpoint.host, "localhost")
        case .failure(let error): XCTFail("loopback refused: \(error)")
        }
    }

    func testSchemeWithNoHostIsNamed() {
        XCTAssertEqual(failure("https://"), .missingHost)
        XCTAssertEqual(failure("https:///v1/health"), .missingHost)
    }

    func testEveryRefusedShapeSaysWhy() {
        // A refusal that does not name its reason is a refusal the owner cannot act on.
        for raw in ["", "duckdns.org", "ftp://x.org", "http://x.org", "https://"] {
            guard let error = failure(raw) else { continue }
            XCTAssertFalse(error.description.isEmpty, "empty description for \(raw.debugDescription)")
        }
    }
}
