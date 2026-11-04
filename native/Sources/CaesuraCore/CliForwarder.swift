import Foundation

/// IPC between the CLI (and second GUI launches) and the single running GUI instance.
/// A UNIX domain socket lives in the data directory; payloads are JSON `{"argv": [...]}`.
/// No shell is involved anywhere, so untrusted arguments are never interpolated.
public enum CliForwarder {
    public enum Result: Equatable {
        case forwarded
        case noInstance
        case failed(String)
    }

    /// The largest answer the client accepts: a status reply is a small JSON
    /// object, and a bigger one is a broken peer, never a truncated answer.
    private static let maximumReplyBytes = 1_048_576

    public static func forward(argvJSON: Data, socketURL: URL, connectTimeout: TimeInterval = 2) -> Result {
        switch open(socketURL: socketURL, connectTimeout: connectTimeout) {
        case .failed(let result):
            return result
        case .connected(let fd):
            defer { close(fd) }
            return sendFrame(fd, payload: argvJSON)
        }
    }

    /// Sends a frame to the running instance and waits for its answer.
    ///
    /// The answer is the reply of the server (one JSON payload, one line). It
    /// is how the client learns something about the process that is really
    /// running — the accessibility permission of the *application*, not of the
    /// client that asks.
    ///
    /// The answer has to arrive as a whole line: a connection that ends or a
    /// timeout that passes before the line is complete is a failure, never a
    /// half answer.
    public static func request(argvJSON: Data, socketURL: URL,
                               connectTimeout: TimeInterval = 2,
                               replyTimeout: TimeInterval = 5) -> (Result, String?) {
        switch open(socketURL: socketURL, connectTimeout: connectTimeout) {
        case .failed(let result):
            return (result, nil)
        case .connected(let fd):
            defer { close(fd) }
            let result = sendFrame(fd, payload: argvJSON)
            guard result == .forwarded else { return (result, nil) }
            return (result, readReply(fd, timeout: replyTimeout))
        }
    }

    /// Opens the socket of the running instance.
    private enum Open {
        case connected(Int32)
        case failed(Result)
    }

    private static func open(socketURL: URL, connectTimeout: TimeInterval) -> Open {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed(.failed("socket() failed: \(errno)")) }
        // A peer that closes the connection must not kill this process with a
        // signal (Darwin): the write simply fails with EPIPE.
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return .failed(.failed("socket path too long"))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                var flags = fcntl(fd, F_GETFL, 0)
                flags |= O_NONBLOCK
                _ = fcntl(fd, F_SETFL, flags)
                return connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult != 0 {
            // ENOENT/ECONNREFUSED: no listener. ENOTSOCK/EPROTOTYPE: path is a regular
            // file or a stale non-socket.
            if errno == ECONNREFUSED || errno == ENOENT || errno == ENOTSOCK || errno == EPROTOTYPE {
                close(fd)
                return .failed(.noInstance)
            }
            if errno == EINPROGRESS || errno == EALREADY {
                var pollSet = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&pollSet, 1, Int32(connectTimeout * 1000))
                guard polled > 0 else {
                    close(fd)
                    return .failed(.noInstance)
                }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error != 0 {
                    close(fd)
                    return .failed(.noInstance)
                }
            } else {
                close(fd)
                return .failed(.failed("connect failed: \(errno)"))
            }
        }
        return .connected(fd)
    }

    /// Sends one newline-terminated frame.
    private static func sendFrame(_ fd: Int32, payload: Data) -> Result {
        var sendBuffer = payload
        sendBuffer.append(0x0A) // newline-terminated frame
        let sent = sendBuffer.withUnsafeBytes { raw -> Int in
            send(fd, raw.baseAddress, raw.count, 0)
        }
        guard sent == sendBuffer.count else {
            return .failed("send failed: \(errno)")
        }
        return .forwarded
    }

    /// Reads the reply of the server: one newline-terminated frame. A frame
    /// that does not arrive as a whole line is no answer at all.
    private static func readReply(_ fd: Int32, timeout: TimeInterval) -> String? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pollSet = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&pollSet, 1, 50)
            guard polled > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4_096) }
            if count == 0 { break } // the peer closed the connection
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > maximumReplyBytes { return nil }
            if buffer.last == 0x0A {
                buffer.removeLast()
                return String(data: buffer, encoding: .utf8)
            }
        }
        return nil
    }
}
