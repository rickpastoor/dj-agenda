import Darwin
import Foundation
import Network

/// Klein webservertje zodat de Sonos de DJ-audio van de Mac kan ophalen.
/// Serveert alleen WAV-bestanden uit `AudioFiles.directory`.
final class AudioServer: @unchecked Sendable {
    /// Gewenste poort; is die bezet, dan de eerste vrije daarna.
    let preferredPort: UInt16
    private(set) var port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nl.rickpastoor.dj-agenda.http")

    init(port: UInt16 = 8765) {
        preferredPort = port
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }
        port = (preferredPort..<preferredPort + 20).first(where: Self.isFree) ?? preferredPort
        let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state { log.error("Audioserver: \(e.localizedDescription, privacy: .public)") }
        }
        l.start(queue: queue)
        listener = l
        log.info("Audioserver op poort \(self.port)")
    }

    func url(for file: URL, host: String) -> URL {
        URL(string: "http://\(host):\(port)/\(file.lastPathComponent)")!
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self?.respond(conn, to: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buf.count > 65_536 {
                conn.cancel()
            } else {
                self?.receiveRequest(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, to request: String) {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : "/"
        // Alleen een bestandsnaam: geen mappen, geen "..".
        let name = (path.removingPercentEncoding ?? path).split(separator: "/").last.map(String.init) ?? ""
        let file = AudioFiles.directory.appendingPathComponent(name)

        guard ["GET", "HEAD"].contains(method), name.hasSuffix(".wav"), !name.hasPrefix("."),
              let body = try? Data(contentsOf: file) else {
            send(conn, status: "404 Not Found", type: "text/plain", body: Data("not found".utf8))
            return
        }
        log.info("Audioserver: \(method, privacy: .public) \(name, privacy: .public) (\(body.count) bytes)")
        send(conn, status: "200 OK", type: "audio/wav", body: method == "HEAD" ? nil : body, length: body.count)
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: Data?, length: Int? = nil) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length ?? body?.count ?? 0)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Is de poort vrij? (Even proberen te binden, op IPv6 en IPv4.)
    static func isFree(_ port: UInt16) -> Bool {
        func tryBind(_ family: Int32) -> Bool {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            if family == AF_INET6 {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                addr.sin6_addr = in6addr_any
                return withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                    }
                }
            }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }
        return tryBind(AF_INET6) && tryBind(AF_INET)
    }

    /// Ons eigen LAN-adres op het netwerk-interface richting de Sonos (er gaat niets over de lijn:
    /// een UDP-"connect" laat alleen de routering kiezen).
    static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1400).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
        }
        guard got else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
