import Foundation

/// UNIX domain socket listener that receives CLI forwarding frames
/// (`{"argv": [...]}` newline-terminated JSON) in the single running GUI instance.
public final class CliServer {
    /// `lastError` value when the socket is already owned by a running instance.
    public static let errorSocketOwned = "socket owned by another instance"

    public var onArgv: (([String]) -> Void)?
    public private(set) var lastError: String = ""
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "caesura.cli-server")
    private let clientQueue = DispatchQueue(label: "caesura.cli-server.client", attributes: .concurrent)
    private var boundPath: String?

    public init() {}

    /// Binds the socket. Returns false when another instance owns it.
    public func start(socketURL: URL) -> Bool {
        stop()
        lastError = ""
        let manager = FileManager.default
        try? manager.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Detect a stale socket: if it exists and refuses connections, remove it.
        if manager.fileExists(atPath: socketURL.path) {
            let probe = CliForwarder.forward(argvJSON: Data("{\"argv\":[\"noop-probe\"]}".utf8), socketURL: socketURL)
            if probe == .noInstance {
                try? manager.removeItem(at: socketURL)
            } else {
                lastError = Self.errorSocketOwned
                return false
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastError = "socket errno \(errno)"
            return false
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            lastError = "socket path too long (\(pathBytes.count))"
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            lastError = "bind errno \(errno)"
            return false
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            lastError = "listen errno \(errno)"
            return false
        }
        listenFD = fd
        boundPath = socketURL.path

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            // Each client is served off the accept queue so that a stalled or partial
            // frame cannot block further connections.
            self.clientQueue.async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
        // The cancel handler must not close the descriptor: `stop()` owns that, so the
        // descriptor is never closed twice (which could close a reused fd).
        source.setCancelHandler { }
        source.resume()
        acceptSource = source
        return true
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        closeListenFD()
        removeSocketFile()
    }

    /// Closes the listening descriptor exactly once.
    private func closeListenFD() {
        guard listenFD >= 0 else { return }
        let fd = listenFD
        listenFD = -1
        close(fd)
    }

    private func removeSocketFile() {
        guard let boundPath else { return }
        try? FileManager.default.removeItem(atPath: boundPath)
        self.boundPath = nil
    }

    deinit {
        stop()
    }

    private func handle(clientFD: Int32) {
        var buffer = Data()
        let chunkSize = 4096
        let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer {
            chunk.deallocate()
            close(clientFD)
        }
        // A client that connects without sending a complete frame must not block the
        // server: the read times out after two seconds.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        while buffer.count < 1_000_000 {
            let readCount = read(clientFD, chunk, chunkSize)
            if readCount <= 0 { break }
            buffer.append(chunk.assumingMemoryBound(to: UInt8.self), count: readCount)
            if buffer.last == 0x0A { break }
        }
        if buffer.last == 0x0A { buffer.removeLast() }
        guard let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
              let argv = object["argv"] as? [String] else { return }
        // Delivered on the server queue; UI handlers hop to the main thread themselves.
        self.onArgv?(argv)
    }
}
