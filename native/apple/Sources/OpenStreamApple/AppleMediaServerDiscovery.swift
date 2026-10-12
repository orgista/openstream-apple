import Darwin
import Foundation

public struct AppleDiscoveredMediaServer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: URL

    public static func decode(_ data: Data) -> Self? {
        struct Announcement: Decodable {
            let Id: String
            let Name: String
            let Address: String
        }
        guard let value = try? JSONDecoder().decode(Announcement.self, from: data),
              !value.Id.isEmpty, !value.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: value.Address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return Self(id: value.Id, name: value.Name, baseURL: url)
    }
}

public enum AppleMediaServerDiscovery {
    /// A short, cancellable scan. The socket is owned by this invocation and
    /// always closes, including when the setup page goes away.
    @concurrent public static func discover() async -> [AppleDiscoveredMediaServer] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return [] }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        let query = Array("who is JellyfinServer?".utf8)
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let interface = current.pointee
            guard interface.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                  let address = interface.ifa_dstaddr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var destination = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            destination.sin_port = UInt16(7359).bigEndian
            _ = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                    query.withUnsafeBytes { sendto(descriptor, $0.baseAddress, $0.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
        var found: [String: AppleDiscoveredMediaServer] = [:]
        let deadline = ContinuousClock.now + .seconds(3)
        var buffer = [UInt8](repeating: 0, count: 8192)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0, let server = AppleDiscoveredMediaServer.decode(Data(buffer.prefix(count))) {
                found[server.id] = server
            } else {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return [] }
            }
        }
        guard !Task.isCancelled else { return [] }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
