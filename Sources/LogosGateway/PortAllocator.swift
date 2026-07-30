import Foundation

public enum PortAllocationError: Error, Equatable {
    case socketCreationFailed(code: Int32)
    case bindFailed(code: Int32)
    case getsocknameFailed(code: Int32)
    /// Every probe returned a port already handed out this process.
    case exhausted
}

/// Hands out free loopback ports for gateway children.
///
/// The proxy binds the port itself from `RATE_LIMIT_PROXY_PORT`, and its
/// readiness line prints the port it was *asked* for rather than the one it
/// bound — so `RATE_LIMIT_PROXY_PORT=0` would let the OS choose but leave the
/// choice unrecoverable. Logos therefore picks a concrete port up front by
/// binding `127.0.0.1:0`, reading the assignment back, and closing.
///
/// Closing before the child binds leaves a small TOCTOU window. It is accepted
/// rather than engineered away: holding the socket open would stop the child
/// binding at all, and the caller retries on a bind failure.
public actor PortAllocator {

    private var handedOut: Set<UInt16> = []

    public init() {}

    /// Ports currently considered in use. Exposed for tests.
    public var heldPorts: Set<UInt16> { handedOut }

    public func allocate(maxAttempts: Int = 16) throws -> UInt16 {
        for _ in 0..<maxAttempts {
            let port = try Self.probeFreePort()
            if !handedOut.contains(port) {
                handedOut.insert(port)
                return port
            }
        }
        throw PortAllocationError.exhausted
    }

    public func release(_ port: UInt16) {
        handedOut.remove(port)
    }

    /// Bind `127.0.0.1:0`, read back the OS-assigned port, close.
    static func probeFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PortAllocationError.socketCreationFailed(code: errno) }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                          // 0 asks the OS to assign
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw PortAllocationError.bindFailed(code: errno) }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(fd, generic, &length)
            }
        }
        guard nameResult == 0 else { throw PortAllocationError.getsocknameFailed(code: errno) }

        return UInt16(bigEndian: bound.sin_port)
    }
}
