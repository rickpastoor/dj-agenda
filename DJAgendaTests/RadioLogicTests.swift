import XCTest
@testable import DJAgenda

/// Nep-Spotify: een afspeellijst met vaste nummerduren, die je kunt pauzeren en doorskippen.
struct FakeSpotify {
    var durations: [TimeInterval]
    var startedAt: Date
    /// Vanaf wanneer er muziek speelt (daarvoor: gepauzeerd).
    var playingFrom: Date
    var pausedAt: Date?
    /// Extra tijd vooruit in de afspeellijst (doorskippen).
    var skipped: TimeInterval = 0

    func state(at t: Date) -> PlayerState {
        if t < playingFrom { return PlayerState(status: .paused, trackID: "") }
        let effective = min(t, pausedAt ?? t)
        var elapsed = effective.timeIntervalSince(playingFrom) + skipped
        for (i, d) in durations.enumerated() {
            if elapsed < d {
                return PlayerState(status: pausedAt == nil ? .playing : .paused,
                                   position: elapsed, duration: d,
                                   title: "Nummer \(i + 1)", artist: "Artiest \(i + 1)",
                                   volume: 70, trackID: "track-\(i + 1)")
            }
            elapsed -= d
        }
        return PlayerState(status: .stopped)
    }

    /// Spring naar het begin van het volgende nummer.
    mutating func skip(at t: Date) {
        let st = state(at: t)
        skipped += st.duration - st.position
    }
}

/// Laat de logica draaien met een nep-klok, zoals de echte lus doet.
struct Simulation {
    var logic = RadioLogic()
    var spotify: FakeSpotify
    var events: [AgendaEvent]
    var now: Date
    var spoken: [(at: Date, request: DJRequest, mode: SpeakMode)] = []
    var prepared: [(at: Date, request: DJRequest)] = []

    init(spotify: FakeSpotify, events: [AgendaEvent], now: Date) {
        self.spotify = spotify
        self.events = events
        self.now = now
    }

    mutating func run(until end: Date, beforeTick: ((inout Simulation) -> Void)? = nil) {
        while now < end {
            beforeTick?(&self)
            let decision = logic.tick(now: now, player: spotify.state(at: now), events: events)
            for action in decision.actions {
                switch action {
                case .prepare(let r):
                    prepared.append((now, r))
                case .speak(let r, let mode):
                    spoken.append((now, r, mode))
                    if mode != .overIntro && mode != .overOutro { spotify.pausedAt = now }
                }
            }
            // Niet langer slapen dan 0,5 s, zodat een gemiste stap opvalt.
            now = now.addingTimeInterval(min(decision.sleep, 0.5))
        }
    }
}

final class RadioLogicTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func meeting(_ title: String = "Weekly", at s: TimeInterval, travel: Int = 0) -> AgendaEvent {
        AgendaEvent(key: title, title: title, start: at(s), travelMinutes: travel)
    }

    func playlist(_ d: TimeInterval = 200, count: Int = 20, from s: TimeInterval = 0) -> FakeSpotify {
        FakeSpotify(durations: Array(repeating: d, count: count), startedAt: t0, playingFrom: at(s))
    }

    // MARK: - Scenario's

    func testNoMusicNoDJ() {
        var sim = Simulation(spotify: playlist(from: 10_000), events: [meeting(at: 900)], now: t0)
        sim.run(until: at(1200))
        XCTAssertTrue(sim.spoken.isEmpty, "Geen muziek, geen DJ")
    }

    func testTalksAtEveryTransitionInRunUpThenPausesBeforeStart() {
        // Nummers van 200 s, meeting na 900 s. Aanloop vanaf 180 s.
        var sim = Simulation(spotify: playlist(), events: [meeting(at: 900)], now: t0)
        sim.run(until: at(1000))

        // De DJ begint 7 s voor het einde, over de outro heen (zoals op de radio).
        let transitions = sim.spoken.filter { $0.request.kind == .transition }
        XCTAssertEqual(transitions.map(\.mode), [.overOutro, .overOutro, .overOutro])
        XCTAssertEqual(transitions.map { $0.at.timeIntervalSince(t0).rounded() }, [193, 393, 593])
        XCTAssertEqual(transitions.map { $0.request.previous?.title }, ["Nummer 1", "Nummer 2", "Nummer 3"])

        // Nummer 4 eindigt op 800 s; de meeting begint 100 s later: geen nieuw nummer meer.
        let finals = sim.spoken.filter { $0.request.kind == .final }
        XCTAssertEqual(finals.count, 1)
        XCTAssertEqual(finals[0].mode, .pauseThenSpeak)
        XCTAssertEqual(finals[0].at.timeIntervalSince(t0), 799, accuracy: 1)
        XCTAssertEqual(sim.spoken.count, 4, "Daarna niets meer")
    }

    func testTransitionOutsideRunUpIsSilent() {
        var sim = Simulation(spotify: playlist(), events: [meeting(at: 2000)], now: t0)
        sim.run(until: at(1100))
        XCTAssertTrue(sim.spoken.isEmpty, "Wissels op 200…1000 s liggen vóór de aanloop (vanaf 1280 s)")
    }

    func testLongTrackFinalOverMusicAtStart() {
        var sim = Simulation(spotify: playlist(1200), events: [meeting(at: 600)], now: t0)
        sim.run(until: at(700))
        XCTAssertEqual(sim.spoken.count, 1)
        XCTAssertEqual(sim.spoken[0].request.kind, .final)
        XCTAssertEqual(sim.spoken[0].mode, .overMusicThenPause)
        XCTAssertEqual(sim.spoken[0].at.timeIntervalSince(t0), 600, accuracy: 0.6)
    }

    func testManualSkipCountsAsTransition() {
        var sim = Simulation(spotify: playlist(300), events: [meeting(at: 1000)], now: t0)
        var didSkip = false
        sim.run(until: at(500)) { sim in
            if !didSkip, sim.now >= self.at(450) {
                sim.spotify.skip(at: sim.now)
                didSkip = true
            }
        }
        // Aanloop vanaf 280 s: over de outro van nummer 1 (293 s), en het doorskippen op 450 s
        // (dan over het begin van het nieuwe nummer).
        let times = sim.spoken.map { $0.at.timeIntervalSince(t0).rounded() }
        XCTAssertEqual(times, [293, 450])
        XCTAssertEqual(sim.spoken.map(\.mode), [.overOutro, .overIntro])
        XCTAssertEqual(sim.spoken.last?.request.previous?.title, "Nummer 2")
    }

    func testMusicStartingLateStillGetsFinal() {
        var sim = Simulation(spotify: playlist(from: 930), events: [meeting(at: 900)], now: t0)
        sim.run(until: at(1000))
        XCTAssertEqual(sim.spoken.count, 1)
        XCTAssertEqual(sim.spoken[0].request.kind, .final)
        XCTAssertEqual(sim.spoken[0].at.timeIntervalSince(t0), 930, accuracy: 1)
    }

    func testMusicStartingTooLateIsIgnored() {
        var sim = Simulation(spotify: playlist(from: 1000), events: [meeting(at: 900)], now: t0)
        sim.run(until: at(1300))
        XCTAssertTrue(sim.spoken.isEmpty)
    }

    func testTravelUsesDepartureTime() {
        // Begint op 1000 s, 10 min reistijd: vertrek op 400 s. Nummer 2 eindigt op 400 s.
        var sim = Simulation(spotify: playlist(), events: [meeting("Trein", at: 1000, travel: 10)], now: t0)
        sim.run(until: at(600))
        XCTAssertEqual(sim.spoken.map(\.request.kind), [.transition, .final])
        XCTAssertEqual(sim.spoken[1].mode, .pauseThenSpeak)
        XCTAssertTrue(DJText.finalText(sim.spoken[1].request).contains("vertrekken voor Trein"))
    }

    func testEventsAtSameTimeGoTogether() {
        let events = [meeting("Weekly", at: 900), meeting("Demo", at: 930)]
        var sim = Simulation(spotify: playlist(1200), events: events, now: t0)
        sim.run(until: at(1000))
        XCTAssertEqual(sim.spoken.count, 1)
        XCTAssertEqual(sim.spoken[0].request.events.map(\.title), ["Weekly", "Demo"])
        XCTAssertTrue(DJText.finalText(sim.spoken[0].request).contains("Weekly en Demo"))
    }

    func testPreparesSameRequestItLaterSpeaks() {
        var sim = Simulation(spotify: playlist(), events: [meeting(at: 900)], now: t0)
        sim.run(until: at(1000))
        for s in sim.spoken {
            let earlier = sim.prepared.filter { $0.at < s.at && $0.request.signature == s.request.signature }
            XCTAssertFalse(earlier.isEmpty, "Niet klaargezet: \(s.request.signature)")
            // Tekst en stem duren samen zo'n 4 s; de aanloop begint hier pas 13 s voor de eerste wissel.
            XCTAssertGreaterThanOrEqual(s.at.timeIntervalSince(earlier.first!.at), 10)
        }
    }

    func testNoDoubleTalkAfterOutro() {
        // Na het praten over de outro komt de wissel zelf: dan niet nog eens.
        var sim = Simulation(spotify: playlist(), events: [meeting(at: 900)], now: t0)
        sim.run(until: at(450))
        XCTAssertEqual(sim.spoken.map { $0.at.timeIntervalSince(t0).rounded() }, [193, 393])
    }

    func testShortTrackRightAfterStartGetsNoOutroTalk() {
        // Een nummer van 5 s: te kort om over de outro te praten (positie < 6 s).
        var spotify = playlist()
        spotify.durations[1] = 5
        var sim = Simulation(spotify: spotify, events: [meeting(at: 900)], now: t0)
        sim.run(until: at(210))
        XCTAssertEqual(sim.spoken.map { $0.at.timeIntervalSince(t0).rounded() }, [193])
    }

    func testDeclinedCanceledAllDayNeverReachTheDJ() {
        var raws = [RawEvent(identifier: "a", title: "Afgeslagen", start: at(900)),
                    RawEvent(identifier: "b", title: "Geannuleerd", start: at(900)),
                    RawEvent(identifier: "c", title: "Hele dag", start: at(900))]
        raws[0].declinedByMe = true
        raws[1].isCanceled = true
        raws[2].isAllDay = true
        let events = raws.compactMap { EventFilter.event(from: $0, skipKeywords: []) }
        var sim = Simulation(spotify: playlist(), events: events, now: t0)
        sim.run(until: at(1000))
        XCTAssertTrue(sim.spoken.isEmpty)
    }
}

final class DutchSpeechTests: XCTestCase {
    func testNumbers() {
        XCTAssertEqual(DutchSpeech.number(12), "twaalf")
        XCTAssertEqual(DutchSpeech.number(22), "tweeëntwintig")
        XCTAssertEqual(DutchSpeech.number(24), "vierentwintig")
        XCTAssertEqual(DutchSpeech.number(31), "eenendertig")
        XCTAssertEqual(DutchSpeech.minutes(1), "een minuut")
        XCTAssertEqual(DutchSpeech.minutes(15), "een kwartier")
        XCTAssertEqual(DutchSpeech.minutes(4), "vier minuten")
    }

    func testClock() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        func t(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: h, minute: m))!
        }
        XCTAssertEqual(DutchSpeech.clock(t(15, 0), calendar: cal), "drie uur")
        XCTAssertEqual(DutchSpeech.clock(t(14, 30), calendar: cal), "half drie")
        XCTAssertEqual(DutchSpeech.clock(t(14, 15), calendar: cal), "kwart over twee")
        XCTAssertEqual(DutchSpeech.clock(t(14, 45), calendar: cal), "kwart voor drie")
        XCTAssertEqual(DutchSpeech.clock(t(14, 20), calendar: cal), "tien voor half drie")
        XCTAssertEqual(DutchSpeech.clock(t(14, 40), calendar: cal), "tien over half drie")
        XCTAssertEqual(DutchSpeech.clock(t(12, 5), calendar: cal), "vijf over twaalf")
        XCTAssertEqual(DutchSpeech.clock(t(23, 50), calendar: cal), "tien voor twaalf")
    }
}

final class DJTextTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func request(minutes: Double, travel: Int = 0, location: String = "") -> DJRequest {
        var ev = AgendaEvent(key: "k", title: "Weekly", start: t0.addingTimeInterval(minutes * 60 + Double(travel) * 60))
        ev.travelMinutes = travel
        ev.location = location
        return DJRequest(kind: .transition, events: [ev], at: t0,
                         previous: TrackInfo(id: "x", title: "Wake Me Up", artist: "Avicii"))
    }

    func testFallback() {
        let text = DJText.fallback(request(minutes: 12, location: "Zaal 3"))
        XCTAssertTrue(text.hasPrefix("Dat was Wake Me Up van Avicii. Over twaalf minuten begint Weekly, om "))
        XCTAssertTrue(DJText.closingsRelaxed.contains { text.hasSuffix(", in Zaal 3. " + $0) }, text)
        let soon = DJText.fallback(request(minutes: 4))
        XCTAssertTrue(DJText.closingsSoon.contains { soon.hasSuffix($0) }, soon)
        XCTAssertTrue(DJText.fallback(request(minutes: 8, travel: 10))
            .contains("Over acht minuten moet je vertrekken voor Weekly."))
        XCTAssertFalse(DJText.fallback(request(minutes: 8, location: "https://meet.x/y")).contains("https"))
    }

    func testApplePromptHasSpokenTimesOnly() {
        let prompt = DJText.applePrompt(request(minutes: 12))
        XCTAssertTrue(prompt.contains("begint over twaalf minuten, om "))
        let body = prompt.replacingOccurrences(of: "\nDJ:", with: "")
        XCTAssertNil(body.rangeOfCharacter(from: .decimalDigits), "Geen cijfers in de opdracht: \(prompt)")
    }

    func testPlausibility() {
        let prompt = "Opdracht: Afspraak: Weekly, begint over twaalf minuten, om drie uur.\nDJ:"
        XCTAssertTrue(DJText.isPlausible("Over twaalf minuten de weekly, om drie uur.", prompt: prompt))
        XCTAssertFalse(DJText.isPlausible("Over een uur is het tijd voor de weekly.", prompt: prompt),
                       "Verzonnen tijdsduur (zagen we echt bij het Apple-model)")
        XCTAssertFalse(DJText.isPlausible("Over vijf minuten de weekly.", prompt: prompt), "Verzonnen getal")
        XCTAssertFalse(DJText.isPlausible("Om 15:00 de weekly.", prompt: prompt), "Cijfers")
        XCTAssertFalse(DJText.isPlausible("Hoi", prompt: prompt), "Te kort")
    }

    func testClosingsAndFinalsVary() {
        let req = request(minutes: 12)
        let first = DJText.fallback(req)
        for _ in 0..<20 {
            let next = DJText.fallback(req, avoiding: [first])
            XCTAssertFalse(DJText.closingsRelaxed.contains { first.hasSuffix($0) && next.hasSuffix($0) },
                           "Zelfde afsluiting twee keer achter elkaar")
        }
        var final = req
        final.kind = .final
        let f1 = DJText.finalText(final)
        for _ in 0..<20 { XCTAssertNotEqual(DJText.finalText(final, avoiding: [f1]), f1) }
    }

    func testPromptIncludesNotesAndAttendees() {
        var req = request(minutes: 12)
        req.events[0].notes = "Prioriteiten voor Q3 doornemen."
        req.events[0].attendees = ["Sanne", "Joris"]
        req.events[0].attendees = ["Sanne de Vries", "Joris Bakker"]
        let prompt = DJText.applePrompt(req)
        XCTAssertTrue(prompt.contains("Omschrijving: Prioriteiten voor Q3 doornemen."))
        XCTAssertTrue(prompt.contains("Met: Sanne en Joris."), "Alleen voornamen")
        // "Q3" staat in de opdracht, dus dat mag; "Q4" niet.
        XCTAssertTrue(DJText.isPlausible("Over twaalf minuten Q3 met Sanne.", prompt: prompt))
        XCTAssertFalse(DJText.isPlausible("Over twaalf minuten Q4 met Sanne.", prompt: prompt))
        let payload = DJText.llmPayload(req)
        XCTAssertTrue(payload.contains("\"people\":[\"Sanne\",\"Joris\"]"), payload)
    }

    func testDurationsMustMatch() {
        // Dit zei het Apple-model echt: zeven minuten klopt, elf (uit de kloktijd) niet.
        var req = request(minutes: 7)
        req.events[0].attendees = ["Eva"]
        let prompt = "Opdracht: Afspraak: Weekly, begint over zeven minuten, om elf over half negen.\nDJ:"
        XCTAssertTrue(DJText.isPlausible("Over zeven minuten de weekly met Eva.", prompt: prompt, request: req))
        XCTAssertFalse(DJText.isPlausible("Over zeven minuten de weekly. Nog elf minuten, hou vol.",
                                          prompt: prompt, request: req))
        XCTAssertFalse(DJText.isPlausible("Over een kwartier de weekly.", prompt: prompt, request: req))
    }

    func testRepeatsDetectsCopiedPhrases() {
        var req = request(minutes: 7)
        req.events[0].attendees = ["Eva Mulder", "Daan Peters"]
        let before = "Dreams, een stap achteruit. Over zeven minuten de weekly met Eva en Daan, nog geen echte conclusie."
        XCTAssertTrue(DJText.repeats("Kom van dat dak af. Over vier minuten de weekly, nog geen echte conclusie.",
                                     recent: [before], request: req))
        XCTAssertFalse(DJText.repeats("Kom van dat dak af, dat doen we maar niet. Over vier minuten de weekly met Eva en Daan.",
                                      recent: [before], request: req), "Titel en namen tellen niet als herhaling")
    }

    func testClean() {
        XCTAssertEqual(DJText.clean("DJ: \"Hallo daar.\"\n"), "Hallo daar.")
    }
}
