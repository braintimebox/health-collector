import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A reply as the transport saw it. The transport does not interpret status codes:
/// that is a contract question, and it lives in one place — `decode`.
public struct HTTPReply: Equatable {
    public let status: Int
    public let retryAfter: TimeInterval?
    public let body: Data

    public init(status: Int, retryAfter: TimeInterval? = nil, body: Data) {
        self.status = status
        self.retryAfter = retryAfter
        self.body = body
    }
}

/// The client half of the measurement route (`POST /v1/measurements`).
///
/// The server owns the JSON envelope (the spec is the authority); this type is the
/// single place where the client agrees with it. Two rules from the spec are load
/// bearing and are enforced here rather than trusted to the caller:
///
/// - a `200` that does not name accepted records is **not** an acknowledgement: it
///   throws `malformedAck`, and the engine keeps the rows queued;
/// - a batch that fails as a whole (400/413/422) dead-letters, while a credential
///   problem (401/403) never destroys data — it retries, because a token is a thing
///   that gets fixed.
/// Failures the client can see before a byte leaves the phone.
public enum ClientError: Error, Equatable {
    /// The spec makes `identity.user_id` mandatory equal to the token's user, and the
    /// server answers `401 identity_mismatch` for the whole batch when it is not. A
    /// record built for another user is a local defect, so it is caught here instead
    /// of being discovered as a 401 that looks like a credential problem.
    case identityMismatch(recordID: String, batchUser: String, recordUser: String)
}

public enum MeasurementClient {
    public static let path = ApiRoute.measurements
    public static let tokenHeader = "Authorization"

    // MARK: Request

    public static func requestBody(batch: WireBatch) throws -> Data {
        try validate(batch)
        return try WireCodec.encoder().encode(batch)
    }

    static func validate(_ batch: WireBatch) throws {
        for record in batch.records where record.identity.userID != batch.userID {
            throw ClientError.identityMismatch(
                recordID: record.identity.recordID,
                batchUser: batch.userID,
                recordUser: record.identity.userID
            )
        }
        for deletion in batch.deletes where deletion.identity.userID != batch.userID {
            throw ClientError.identityMismatch(
                recordID: deletion.identity.recordID,
                batchUser: batch.userID,
                recordUser: deletion.identity.userID
            )
        }
    }

    public static func makeRequest(batch: WireBatch, baseURL: URL, token: String) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(ApiRoute.relative(ApiRoute.measurements))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: tokenHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try requestBody(batch: batch)
        return request
    }

    // MARK: Response

    private struct AckBody: Decodable {
        let accepted: [String]?
        let rejected: [RejectedEntry]?
    }

    private struct RejectedEntry: Decodable {
        let recordID: String
        let reason: String
        let permanent: Bool

        // Spelled out instead of a decoding strategy: `convertFromSnakeCase` maps
        // `record_id` to `recordId`, and a property called `recordID` then fails to
        // decode at runtime — measured on this package already.
        private enum CodingKeys: String, CodingKey {
            case recordID = "record_id"
            case reason
            case permanent
        }
    }

    public static func decode(reply: HTTPReply) throws -> ServerAck {
        guard (200...299).contains(reply.status) else {
            throw TransportFailure(
                kind: .http,
                status: reply.status,
                retryAfter: reply.retryAfter,
                message: snippet(reply.body)
            )
        }

        let body: AckBody
        do {
            body = try JSONDecoder().decode(AckBody.self, from: reply.body)
        } catch {
            throw TransportFailure(
                kind: .malformedAck,
                status: reply.status,
                message: "ответ не разбирается как подтверждение: \(snippet(reply.body))"
            )
        }

        // "HTTP 200 без списка accepted клиент обязан считать неподтверждённым":
        // a server that says OK without naming what it stored has told us nothing,
        // and the outbox must keep the rows.
        guard let accepted = body.accepted else {
            throw TransportFailure(
                kind: .malformedAck,
                status: reply.status,
                message: "200 без поля accepted: \(snippet(reply.body))"
            )
        }

        let rejected = (body.rejected ?? []).map {
            RejectedRecord(recordID: $0.recordID, reason: $0.reason, permanent: $0.permanent)
        }
        return ServerAck(accepted: accepted, rejected: rejected)
    }

    private static func snippet(_ data: Data, limit: Int = 200) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}
