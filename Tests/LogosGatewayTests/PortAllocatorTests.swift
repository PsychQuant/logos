import Foundation
import Testing
@testable import LogosGateway

@Suite struct PortAllocatorTests {

    @Test func allocatesAUsablePort() async throws {
        let allocator = PortAllocator()
        let port = try await allocator.allocate()
        #expect(port > 1024)
    }

    /// Two allocations must not collide within one process, even though the OS is
    /// free to hand back the same ephemeral port once the probe socket closes.
    @Test func allocatesDistinctPorts() async throws {
        let allocator = PortAllocator()
        var seen: Set<UInt16> = []
        for _ in 0..<8 {
            let port = try await allocator.allocate()
            #expect(!seen.contains(port))
            seen.insert(port)
        }
        #expect(seen.count == 8)
    }

    /// A released port becomes eligible again.
    @Test func releaseMakesPortReusable() async throws {
        let allocator = PortAllocator()
        let port = try await allocator.allocate()
        #expect(await allocator.heldPorts.contains(port))

        await allocator.release(port)
        #expect(!(await allocator.heldPorts.contains(port)))
    }

    /// The probe must yield a port nothing is listening on, so a child can bind it.
    @Test func allocatedPortIsActuallyBindable() async throws {
        let port = try await PortAllocator().allocate()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(result == 0, "allocated port \(port) was not bindable (errno \(errno))")
    }
}
