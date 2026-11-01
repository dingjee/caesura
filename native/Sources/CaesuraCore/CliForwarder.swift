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

    public static func forward(argvJSON: Data, socketURL: URL, connectTimeout: TimeInterval = 2) -> Result {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket() failed: \(errno)") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return .failed("socket path too long")
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
                return .noInstance
            }
            if errno == EINPROGRESS || errno == EALREADY {
                var pollSet = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let polled = poll(&pollSet, 1, Int32(connectTimeout * 1000))
                guard polled > 0 else { return .noInstance }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error != 0 { return .noInstance }
            } else {
                return .failed("connect failed: \(errno)")
            }
        }

        var sendBuffer = argvJSON
        sendBuffer.append(0x0A) // newline-terminated frame
        let sent = sendBuffer.withUnsafeBytes { raw -> Int in
            send(fd, raw.baseAddress, raw.count, 0)
        }
        guard sent == sendBuffer.count else {
            return .failed("send failed: \(errno)")
        }
        return .forwarded
    }
}
