//
//  Injectable DNS resolver for SSRF-guarded blob URL fetch.
//

import Foundation

struct SessionBlobResolvedAddress: Sendable, Equatable {
    var sockaddrData: Data
    var hostLiteral: String
}

protocol SessionBlobHostResolving: Sendable {
    func resolve(host: String, port: Int) throws -> [SessionBlobResolvedAddress]
}

struct SessionBlobSystemHostResolver: SessionBlobHostResolving {
    func resolve(host: String, port: Int) throws -> [SessionBlobResolvedAddress] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let status = getaddrinfo(host, portString, &hints, &result)
        defer {
            if let result {
                freeaddrinfo(result)
            }
        }
        guard status == 0, let result else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host unresolvable")
        }
        var addresses: [SessionBlobResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let node = cursor {
            let len = Int(node.pointee.ai_addrlen)
            guard len > 0, let addr = node.pointee.ai_addr else {
                cursor = node.pointee.ai_next
                continue
            }
            let data = Data(bytes: addr, count: len)
            guard let literal = literalHost(from: data) else {
                cursor = node.pointee.ai_next
                continue
            }
            addresses.append(SessionBlobResolvedAddress(sockaddrData: data, hostLiteral: literal))
            cursor = node.pointee.ai_next
        }
        guard !addresses.isEmpty else {
            throw SessionPersistenceError.transcriptPayloadInvalid(reason: "blob url host unresolvable")
        }
        return addresses
    }

    private func literalHost(from data: Data) -> String? {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
            switch Int32(base.pointee.sa_family) {
            case AF_INET:
                guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            case AF_INET6:
                guard data.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
                var sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
                return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            default:
                return nil
            }
        }
    }
}
