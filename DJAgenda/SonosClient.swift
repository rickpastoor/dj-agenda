import Foundation
import Network

/// UPnP/SOAP naar een Sonos op poort 1400 (status en besturing), helemaal lokaal.
struct SonosClient: Sendable {
    let host: String

    enum Failure: LocalizedError {
        case http(Int, String)
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let action): "Sonos antwoordde \(code) op \(action)"
            case .missing(let what): "Sonos-antwoord mist \(what)"
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 5
        return URLSession(configuration: c)
    }()

    @discardableResult
    func soap(_ service: String, _ action: String, args: String = "<InstanceID>0</InstanceID>",
              path: String? = nil) async throws -> String {
        let urn = "urn:schemas-upnp-org:service:\(service):1"
        let controlPath = path ?? (service == "ZoneGroupTopology"
            ? "/ZoneGroupTopology/Control" : "/MediaRenderer/\(service)/Control")
        var req = URLRequest(url: URL(string: "http://\(host):1400\(controlPath)")!)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(urn)">\(args)</u:\(action)></s:Body></s:Envelope>
        """.data(using: .utf8)
        let (data, response) = try await Self.session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure.http(code, action) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - AVTransport

    func transportState() async throws -> String {
        let xml = try await soap("AVTransport", "GetTransportInfo")
        guard let s = SonosXML.value("CurrentTransportState", in: xml) else {
            throw Failure.missing("CurrentTransportState")
        }
        return s
    }

    func positionInfo() async throws -> (position: Double, duration: Double, uri: String, title: String, artist: String) {
        let xml = try await soap("AVTransport", "GetPositionInfo")
        let meta = SonosXML.unescape(SonosXML.value("TrackMetaData", in: xml) ?? "")
        return (SonosXML.seconds(SonosXML.value("RelTime", in: xml)),
                SonosXML.seconds(SonosXML.value("TrackDuration", in: xml)),
                SonosXML.unescape(SonosXML.value("TrackURI", in: xml) ?? ""),
                SonosXML.unescape(SonosXML.value("dc:title", in: meta) ?? ""),
                SonosXML.unescape(SonosXML.value("dc:creator", in: meta) ?? ""))
    }

    func pause() async throws { try await soap("AVTransport", "Pause") }

    /// Het volume van deze ene speaker (0–100).
    func volume() async throws -> Int {
        let xml = try await soap("RenderingControl", "GetVolume",
                                 args: "<InstanceID>0</InstanceID><Channel>Master</Channel>")
        guard let v = SonosXML.value("CurrentVolume", in: xml).flatMap({ Int($0) }) else {
            throw Failure.missing("CurrentVolume")
        }
        return v
    }

    /// Alle groepen in huis; elke speaker kent de hele indeling.
    func groups() async throws -> [SonosGroup] {
        let xml = try await soap("ZoneGroupTopology", "GetZoneGroupState", args: "")
        let groups = SonosXML.groups(inZoneGroupState: SonosXML.unescape(SonosXML.value("ZoneGroupState", in: xml) ?? ""))
        guard !groups.isEmpty else { throw Failure.missing("ZoneGroupState") }
        return groups
    }

}

/// Kleine XML-hulpjes; de antwoorden van Sonos zijn voorspelbaar genoeg voor reguliere expressies.
enum SonosXML {
    static func value(_ tag: String, in xml: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))(?:\\s[^>]*)?>(.*?)</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let r = Range(m.range(at: 1), in: xml) else { return nil }
        return String(xml[r])
    }

    static func unescape(_ s: String) -> String {
        var t = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }

    /// "0:03:25" naar seconden; "NOT_IMPLEMENTED" en leeg worden 0.
    static func seconds(_ s: String?) -> Double {
        let parts = (s ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

}

/// Een groep zoals in de Sonos-app: één coördinator (daar speelt Spotify Connect op) en de leden.
struct SonosGroup: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var uuid: String
        var host: String
        var room: String
        /// De tweede speaker van een stereopaar; die tel je niet als aparte kamer.
        var invisible = false
    }

    var coordinator: String
    var members: [Member]

    var coordinatorHost: String? { members.first { $0.uuid == coordinator }?.host }
    var visibleMembers: [Member] { members.filter { !$0.invisible } }

    /// Kamernamen zonder dubbelen, de coördinator voorop.
    var rooms: [String] {
        let visible = visibleMembers
        let ordered = visible.filter { $0.uuid == coordinator } + visible.filter { $0.uuid != coordinator }
        var seen = Set<String>()
        return ordered.map(\.room).filter { seen.insert($0).inserted }
    }

    /// "Living Room + 3", zoals de Sonos-app het laat zien.
    var name: String {
        guard let first = rooms.first else { return coordinator }
        return rooms.count > 1 ? "\(first) + \(rooms.count - 1)" : first
    }

    func contains(room: String) -> Bool {
        rooms.contains { $0.caseInsensitiveCompare(room) == .orderedSame }
    }
}

extension SonosXML {
    /// Alle groepen uit `ZoneGroupState`. Satellieten (surround, sub) zitten in een lid en tellen niet mee.
    static func groups(inZoneGroupState xml: String) -> [SonosGroup] {
        guard let groupRE = try? NSRegularExpression(pattern: #"<ZoneGroup\b([^>]*)>(.*?)</ZoneGroup>"#,
                                                     options: .dotMatchesLineSeparators),
              let memberRE = try? NSRegularExpression(pattern: #"<ZoneGroupMember\b([^>]*)>"#)
        else { return [] }
        func sub(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
        return groupRE.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { g in
            let attrs = attributes(sub(g, 1, xml))
            let body = sub(g, 2, xml)
            guard let coordinator = attrs["Coordinator"] else { return nil }
            let members = memberRE.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { m in
                let a = attributes(sub(m, 1, body))
                guard let uuid = a["UUID"], let host = a["Location"].flatMap({ URL(string: $0)?.host })
                else { return nil as SonosGroup.Member? }
                return SonosGroup.Member(uuid: uuid, host: host, room: unescape(a["ZoneName"] ?? uuid),
                                         invisible: a["Invisible"] == "1")
            }
            return members.isEmpty ? nil : SonosGroup(coordinator: coordinator, members: members)
        }
    }

    static func attributes(_ s: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: #"(\w+)="([^"]*)""#) else { return [:] }
        var out: [String: String] = [:]
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let k = Range(m.range(at: 1), in: s), let v = Range(m.range(at: 2), in: s) {
                out[String(s[k])] = String(s[v])
            }
        }
        return out
    }
}

/// Sonos-speakers vinden via Bonjour (`_sonos._tcp`); de TXT-record bevat het adres.
enum SonosDiscovery {
    struct Speaker: Hashable, Sendable {
        var room: String
        var host: String
        var uuid: String
    }

    static func find(timeout: TimeInterval = 3) async -> [Speaker] {
        let box = Box()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint,
                      case .bonjour(let txt) = r.metadata,
                      let location = txt["location"],
                      let host = URL(string: location)?.host else { continue }
                let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
                box.add(Speaker(room: parts.count > 1 ? parts[1] : name, host: host,
                                uuid: txt["uuid"] ?? parts[0]))
            }
        }
        browser.start(queue: .global())
        try? await Task.sleep(for: .seconds(timeout))
        browser.cancel()
        return box.all.sorted { ($0.room, $0.host) < ($1.room, $1.host) }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items = Set<Speaker>()
        func add(_ s: Speaker) { lock.lock(); items.insert(s); lock.unlock() }
        var all: [Speaker] { lock.lock(); defer { lock.unlock() }; return Array(items) }
    }
}
