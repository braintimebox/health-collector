import Foundation

/// A batch on disk.
///
/// iOS background uploads transfer **from a file**: `uploadTask(with:fromFile:)` is
/// the documented way to keep a transfer alive while the app is suspended or
/// terminated, and sending from memory is not part of that contract. So the batch
/// is written before it is handed to the transport, and the file lives on disk
/// until the transfer is settled.
public final class BatchSpool {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Write the batch and return the URL the upload task reads. Atomic, like the
    /// outbox: a half-written file is worse than no file.
    @discardableResult
    public func write(_ batch: WireBatch, named name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent("batch-\(name).json", isDirectory: false)
        let data = try WireCodec.encoder().encode(batch)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func read(at url: URL) throws -> WireBatch {
        let data = try Data(contentsOf: url)
        return try WireCodec.decoder().decode(WireBatch.self, from: data)
    }

    /// Called once the batch is settled — acknowledged, retried or dead-lettered.
    /// A file that is still needed by a running upload task is never removed
    /// earlier: the task reads it, so it outlives the process.
    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Files left behind by a process that died between writing and settling.
    public func pendingFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// A transport that uploads from a file, which is the shape a background
/// `URLSession` has. The batch reaches it as a URL, not as a value.
public protocol FileBackedTransport: OutboxTransport {
    func send(fileAt url: URL, userID: String) throws -> ServerAck
}
