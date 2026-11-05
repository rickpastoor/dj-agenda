import AppKit
import EventKit

/// Leest afspraken uit Agenda.app via EventKit.
@MainActor
final class CalendarService {
    enum Access: Equatable {
        case unknown, granted, denied
    }

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private(set) var access: Access = .unknown

    /// Wordt aangeroepen als de agenda verandert (`EKEventStoreChanged`).
    var onChange: (() -> Void)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func requestAccess() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            access = granted ? .granted : .denied
        default:
            access = .denied
        }
    }

    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    struct CalendarInfo: Identifiable, Hashable {
        let ref: CalendarRef
        let color: CGColor?
        var id: CalendarRef { ref }
    }

    /// Alle agenda's, voor de instellingen.
    func allCalendars() -> [CalendarInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(ref: CalendarRef(title: $0.title, source: $0.source.title), color: $0.cgColor) }
            .sorted { ($0.ref.source, $0.ref.title) < ($1.ref.source, $1.ref.title) }
    }

    /// `selected == nil`: alle agenda's.
    func upcoming(selected: [CalendarRef]?, skipKeywords: [String], lookaheadHours: Double,
                  now: Date = Date()) -> [AgendaEvent] {
        guard access == .granted else { return [] }
        let cals = store.calendars(for: .event).filter { cal in
            selected?.contains { $0.matches(title: cal.title, source: cal.source.title) } ?? true
        }
        log.debug("Agenda's: \(cals.map { "\($0.title) (\($0.source.title))" }, privacy: .public)")
        guard !cals.isEmpty else { return [] }
        let start = now.addingTimeInterval(-5 * 60)
        let end = now.addingTimeInterval(lookaheadHours * 3600)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)

        var seen = Set<String>()
        return store.events(matching: predicate)
            .compactMap { EventFilter.event(from: Self.raw($0), skipKeywords: skipKeywords) }
            .filter { $0.start >= start && $0.start <= end && seen.insert($0.key).inserted }
            .sorted { $0.alertTime < $1.alertTime }
    }

    private static func raw(_ e: EKEvent) -> RawEvent {
        let declined = (e.attendees ?? []).contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        }
        return RawEvent(
            identifier: e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString,
            title: e.title ?? "",
            start: e.startDate,
            isAllDay: e.isAllDay,
            isCanceled: e.status == .canceled,
            declinedByMe: declined,
            location: e.location ?? "",
            notes: e.notes ?? "",
            attendees: (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap(\.name),
            travelSeconds: travelTime(of: e))
    }

    /// De reistijd uit Agenda.app zit niet in de publieke API. `value(forKey:)` op een sleutel
    /// die niet bestaat gooit een Objective-C-exceptie die Swift niet kan vangen, dus eerst
    /// controleren of de selector bestaat.
    private static func travelTime(of e: EKEvent) -> Double {
        guard e.responds(to: NSSelectorFromString("travelTime")) else { return 0 }
        return (e.value(forKey: "travelTime") as? NSNumber)?.doubleValue ?? 0
    }
}
