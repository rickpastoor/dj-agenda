import Foundation

enum DJText {
    static func isURL(_ s: String) -> Bool {
        s.range(of: #"(?i)^\s*(https?://|www\.)"#, options: .regularExpression) != nil
    }

    static func minutesUntil(_ ev: AgendaEvent, at: Date) -> Int {
        max(0, Int((ev.alertTime.timeIntervalSince(at) / 60).rounded()))
    }

    static func location(_ ev: AgendaEvent) -> String? {
        (!ev.location.isEmpty && !isURL(ev.location)) ? ev.location : nil
    }


    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Kies willekeurig, maar niet hetzelfde als `avoid`.
    static func pick(_ options: [String], avoiding avoid: [String] = [],
                     using rng: inout some RandomNumberGenerator) -> String {
        let fresh = options.filter { o in !avoid.contains { $0.contains(o) } }
        return (fresh.isEmpty ? options : fresh).randomElement(using: &rng)!
    }

    // MARK: - Vaste zinnen

    struct Phrases {
        var finalMeeting: [String]
        var finalLeave: [String]
        var closingsRelaxed: [String]
        var closingsSoon: [String]
    }

    static func phrases(_ lang: Language) -> Phrases {
        switch lang {
        case .nl: Phrases(
            finalMeeting: [
                "Het is tijd voor %@. Ik zet de muziek even stil. Succes!",
                "En daar is het moment: %@ begint. De muziek gaat even op pauze.",
                "Tijd om naar %@ te gaan. Ik draai de muziek even dicht, tot straks!",
                "Dat was het voor nu: %@ begint. Ik zet de muziek op pauze. Zet 'm op!",
            ],
            finalLeave: [
                "Tijd om te gaan: je moet nu vertrekken voor %@. Ik zet de muziek even stil. Goede reis!",
                "Jas aan, sleutels mee: tijd om te vertrekken voor %@. De muziek gaat op pauze.",
                "Nu vertrekken voor %@. Ik zet de muziek even stil, goede reis!",
            ],
            closingsRelaxed: [
                "Nog even genieten van de muziek.", "Je hebt nog even, de muziek gaat door.",
                "Eerst nog dit nummer.", "Geen haast, we draaien nog even door.",
            ],
            closingsSoon: [
                "Tijd om af te ronden.", "Mooi moment om je spullen te pakken.",
                "Rond je zin maar af.", "Nog één nummer, dan is het zover.",
            ])
        case .en: Phrases(
            finalMeeting: [
                "It's time for %@. I'll pause the music for now. Good luck!",
                "And here we are: %@ is starting. The music takes a little break.",
                "Time to head to %@. I'm fading the music out, see you later!",
                "That's it for now: %@ is starting. Music on pause. Go get 'em!",
            ],
            finalLeave: [
                "Time to go: you need to leave now for %@. I'll pause the music. Safe travels!",
                "Coat on, keys in your pocket: time to leave for %@. The music goes on pause.",
                "Off you go to %@. I'll pause the music, have a good trip!",
            ],
            closingsRelaxed: [
                "Plenty of time, enjoy the music.", "No rush, the music keeps going.",
                "First, this one.", "We'll keep spinning for a bit.",
            ],
            closingsSoon: [
                "Time to wrap up.", "Good moment to grab your things.",
                "Finish that sentence.", "One more song, then it's time.",
            ])
        }
    }

    // Voor de bestaande tests (Nederlands).
    static var closingsRelaxed: [String] { phrases(.nl).closingsRelaxed }
    static var closingsSoon: [String] { phrases(.nl).closingsSoon }

    /// De slotzin; altijd een vaste zin, want die moet kloppen. Wel afwisselend.
    static func finalText(_ req: DJRequest, avoiding avoid: [String] = [], lang: Language = .nl) -> String {
        var rng = SystemRandomNumberGenerator()
        return finalText(req, avoiding: avoid, lang: lang, using: &rng)
    }

    static func finalText(_ req: DJRequest, avoiding avoid: [String] = [], lang: Language = .nl,
                          using rng: inout some RandomNumberGenerator) -> String {
        let leave = req.events.contains { $0.travelMinutes > 0 }
        let what = lang.list(req.events.map(\.title))
        let templates = leave ? phrases(lang).finalLeave : phrases(lang).finalMeeting
        let used = avoid.compactMap { a in templates.first { a == String(format: $0, what) } }
        return String(format: pick(templates, avoiding: used, using: &rng), what)
    }

    /// Vaste zin bij een nummerwissel (of als het model iets geks zegt).
    static func fallback(_ req: DJRequest, avoiding avoid: [String] = [], lang: Language = .nl) -> String {
        var rng = SystemRandomNumberGenerator()
        return fallback(req, avoiding: avoid, lang: lang, using: &rng)
    }

    static func fallback(_ req: DJRequest, avoiding avoid: [String] = [], lang: Language = .nl,
                         using rng: inout some RandomNumberGenerator) -> String {
        if req.kind == .final { return finalText(req, avoiding: avoid, lang: lang, using: &rng) }
        let nl = lang == .nl
        var parts: [String] = []
        if let t = req.previous, !t.title.isEmpty {
            parts.append((nl ? "Dat was " : "That was ") + t.title
                         + (t.artist.isEmpty ? "." : (nl ? " van " : " by ") + "\(t.artist)."))
        }
        parts += req.events.map { ev in
            let m = minutesUntil(ev, at: req.at)
            let over = m <= 0 ? (nl ? "Nu" : "Right now") : (nl ? "Over " : "In ") + lang.minutes(m)
            if ev.travelMinutes > 0 {
                return nl ? "\(over) moet je vertrekken voor \(ev.title)."
                          : "\(over) you need to leave for \(ev.title)."
            }
            let waar = location(ev).map { ", in \($0)" } ?? ""
            let met = ev.attendees.isEmpty ? "" : (nl ? ", met " : ", with ") + lang.list(ev.attendees)
            return nl ? "\(over) begint \(ev.title)\(met), om \(lang.clock(ev.start))\(waar)."
                      : "\(over), \(ev.title)\(met), at \(lang.clock(ev.start))\(waar)."
        }
        let soonest = req.events.map { minutesUntil($0, at: req.at) }.min() ?? 99
        let p = phrases(lang)
        parts.append(pick(soonest <= 5 ? p.closingsSoon : p.closingsRelaxed, avoiding: avoid, using: &rng))
        return parts.joined(separator: " ")
    }

    // MARK: - Het lokale model van macOS

    static func appleRules(listener: String) -> String { """
    Je bent de DJ van Radio \(listener), een radiostation voor één luisteraar: \(listener). Tussen de nummers door praat je kort en warm, als op de radio, en herinner je \(listener) aan de volgende afspraak.
    Regels:
    - Nederlands, spreektaal, twee of drie korte zinnen, geen emoji, geen opsommingen.
    - Neem tijden letterlijk over zoals ze in de opdracht staan. Verzin geen details en geen getallen.
    - Staat er een omschrijving of staan er deelnemers bij, dan mag je daar iets mee doen: een naam noemen, of een knipoog naar het onderwerp. Hoeft niet elke keer.
    - Droog gevoel voor humor; soms een knipoog naar het vorige nummer.
    - Varieer! Begin en eindig niet steeds hetzelfde. Een echte DJ zegt niet elke keer "rond maar af".
    """ }

    /// Voorbeelden; per tekst worden er een paar willekeurig gekozen, zodat het niet eentonig wordt.
    static let appleExamples: [(prompt: String, dj: String)] = [
        ("Vorig nummer: Dancing Queen van ABBA. Afspraak: Sprintplanning, begint over een kwartier, om half drie. Met: Sanne en Joris.",
         "Dat was ABBA, en nee, je hoeft nog niet te dansen. Over een kwartier sprintplanning met Sanne en Joris, om half drie."),
        ("Vorig nummer: Under Pressure van Queen. Afspraak: Klantgesprek Bakkerij Jansen, begint over vijf minuten, om elf uur. Omschrijving: Offerte voor de nieuwe website bespreken.",
         "Under Pressure, toepasselijk, want over vijf minuten zit je met Bakkerij Jansen. Die offerte voor de website, je weet wel. Pak er nog even een kop koffie bij."),
        ("Vorig nummer: Here Comes the Sun van The Beatles. Vertrek: je moet over acht minuten weg voor Trein naar Utrecht, die om tien over twee gaat.",
         "Here Comes the Sun, en jij gaat zo de deur uit. Over acht minuten vertrekken voor de trein naar Utrecht. Schoenen staan klaar?"),
        ("Vorig nummer: Bohemian Rhapsody van Queen. Afspraak: Eén-op-één met Lisa, begint over twaalf minuten, om tien uur. Omschrijving: Jaargesprek en doelen voor volgend jaar.",
         "Bohemian Rhapsody, een heel epos, net als een jaargesprek. Over twaalf minuten zit je met Lisa, om tien uur. We draaien nog één plaatje."),
        ("Vorig nummer: Africa van Toto. Afspraak: Weekly design review, begint over zeven minuten, om kwart over drie. Met: Mark, Eva en Tom.",
         "Toto, Africa, verder weg dan dit wordt het vandaag niet. Om kwart over drie de design review met Mark, Eva en Tom, dus nog zeven minuten."),
        ("Vorig nummer: Mr. Blue Sky van Electric Light Orchestra. Afspraak: Tandarts, begint over tien minuten, om half vijf. Locatie: Tandartspraktijk Centrum.",
         "Mr. Blue Sky, en straks een witte lamp in je gezicht. Over tien minuten de tandarts, om half vijf. Tanden poetsen kan nog net."),
        ("Vorig nummer: Superstition van Stevie Wonder. Afspraak: Investeerdersupdate, begint over drie minuten, om twee uur. Omschrijving: Cijfers van het kwartaal en plannen.",
         "Superstition, maar met cijfers heb je geen bijgeloof nodig. Over drie minuten de investeerdersupdate. Nog één nummer, dan ben je aan de beurt."),
    ]

    static func appleInstructions(examples count: Int = 3, listener: String,
                                  using rng: inout some RandomNumberGenerator) -> String {
        let chosen = appleExamples.shuffled(using: &rng).prefix(count)
        let examples = chosen.map { "Opdracht: \($0.prompt)\nDJ: \($0.dj)" }.joined(separator: "\n\n")
        return appleRules(listener: listener) + "\n\nVoorbeelden (alleen ter inspiratie, niet nadoen):\n" + examples
    }

    /// De opdracht voor het lokale model, met alle tijden al uitgeschreven.
    static func applePrompt(_ req: DJRequest) -> String {
        var parts: [String] = []
        if let t = req.previous, !t.title.isEmpty {
            parts.append("Vorig nummer: \(t.title)" + (t.artist.isEmpty ? "." : " van \(t.artist)."))
        }
        for ev in req.events {
            let m = DutchSpeech.minutes(minutesUntil(ev, at: req.at))
            if ev.travelMinutes > 0 {
                parts.append("Vertrek: je moet over \(m) weg voor \(ev.title), die om \(DutchSpeech.clock(ev.start)) begint.")
            } else {
                parts.append("Afspraak: \(ev.title), begint over \(m), om \(DutchSpeech.clock(ev.start)).")
            }
            if let waar = location(ev) { parts.append("Locatie: \(waar).") }
            if !ev.notes.isEmpty { parts.append("Omschrijving: \(ev.notes)") }
            if !ev.attendees.isEmpty { parts.append("Met: \(Language.nl.list(ev.attendees.map(firstName))).") }
        }
        if (req.events.map { minutesUntil($0, at: req.at) }.min() ?? 99) <= 5 {
            parts.append("Toon: het is bijna zover.")
        }
        return "Opdracht: " + parts.joined(separator: " ") + "\nDJ:"
    }

    /// Zegt het model niets geks? Geen getallen die niet in de opdracht stonden, en elke tijdsduur
    /// ("vier minuten", "een kwartier") moet precies kloppen met de afspraak.
    static func isPlausible(_ text: String, prompt: String, request: DJRequest? = nil,
                            lang: Language = .nl) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10, t.count <= 450 else { return false }
        // Cijfers mogen alleen als ze letterlijk in de opdracht staan (bijvoorbeeld "Q3").
        let digitRuns = t.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        let promptRuns = Set(prompt.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
        guard digitRuns.allSatisfy(promptRuns.contains) else { return false }
        guard words(t).filter(lang.numberWords.contains).isSubset(of: words(prompt)) else { return false }
        let lowerText = t.lowercased(), lowerPrompt = prompt.lowercased()
        // Tijdsduren die niet uit losse getalwoorden bestaan ("over een uur").
        let durations = lang == .nl
            ? ["een uur", "anderhalf", "half uur", "halfuur", "een paar minuten", "seconden"]
            : ["an hour", "half an hour", "a few minutes", "couple of minutes", "seconds", "quarter of an hour"]
        guard !durations.contains(where: { lowerText.contains($0) && !lowerPrompt.contains($0) }) else { return false }
        // Elke "… minuten"/"kwartier" moet een van de echte tijdsduren zijn.
        if let request {
            let expected = Set(request.events.map { lang.minutes(minutesUntil($0, at: request.at)) })
            let pattern = lang == .nl
                ? #"\b(\p{L}+ minuten|een minuut|een kwartier|kwartier)\b"#
                : #"\b((?:\p{L}+-)?\p{L}+ minutes|one minute)\b"#
            let found = matches(pattern, in: lowerText)
                .map { $0 == "kwartier" ? "een kwartier" : $0 }
            guard found.allSatisfy(expected.contains) else { return false }
        }
        return true
    }

    /// Lijkt de tekst te veel op een eerdere (drie woorden achter elkaar hetzelfde), los van de
    /// woorden die er nu eenmaal steeds in staan: titel, namen, nummer en artiest, tijden.
    static func repeats(_ text: String, recent: [String], request: DJRequest, lang: Language = .nl) -> Bool {
        var common = words(request.events.map { "\($0.title) \($0.attendees.joined(separator: " ")) \($0.location)" }
            .joined(separator: " "))
        common.formUnion(words("\(request.previous?.title ?? "") \(request.previous?.artist ?? "")"))
        common.formUnion(lang.numberWords)
        common.formUnion(lang == .nl
            ? ["over", "om", "minuten", "minuut", "kwartier", "uur", "half", "kwart", "voor", "de", "het",
               "een", "met", "en", "van", "dat", "was", "begint", "nog"]
            : ["in", "at", "minutes", "minute", "o", "clock", "half", "past", "quarter", "to", "the", "a",
               "with", "and", "by", "that", "was", "starts", "oh", "you", "your"])
        func grams(_ s: String) -> Set<[String]> {
            let w = s.lowercased().components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty && !common.contains($0) }
            guard w.count >= 3 else { return [] }
            return Set((0...(w.count - 3)).map { Array(w[$0..<$0 + 3]) })
        }
        let mine = grams(text)
        return recent.contains { !grams($0).isDisjoint(with: mine) }
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    /// Tekst schoonmaken: aanhalingstekens en een eventueel "DJ:"-voorvoegsel eraf.
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("DJ:") { t = String(t.dropFirst(3)) }
        t = t.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "")
        t = t.replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” \n"))
    }

    // MARK: - Grote modellen via een API (Mistral, Claude): één Engelse prompt, met de taal erin

    static func llmSystem(_ lang: Language, listener: String) -> String {
        let you = lang == .nl ? #" (in Dutch: "je")"# : ""
        return """
        You are the DJ of Radio \(listener), a radio station with exactly one listener: \(listener). Between songs you talk briefly, like a real radio DJ, and remind \(listener) of what's next in their calendar.

        Write only the words you will say out loud. They go straight to a text-to-speech voice, so:
        - Write in \(lang.englishName): natural, spoken \(lang.englishName).
        - Two or three short sentences, at most about 40 words. No emoji, lists, quotation marks, markdown or stage directions.
        - Use the times exactly as given in the data ("in", "at", "now"). Never write digits, and never work out other times or durations.
        - Don't make anything up: only mention what's in the data. Never mention a location that is a web link.
        - Talk to \(listener) as "you"\(you). The appointment is theirs, not yours.
        - You may briefly back-announce the previous song (title and artist), and sometimes wink at the song, the topic of the appointment or the people in it. Not every time.
        - Vary: don't start or end the way you did in "said_before", and don't reuse its jokes.

        Energy: you're an upbeat radio host with a smile in your voice, not someone reading out a calendar.
        - Short, punchy sentences with momentum. An exclamation mark now and then helps the voice sound lively; don't overdo it.
        - Make the countdown the hook, the way a DJ counts down to the top of the hour.
        - Dry humour is welcome, but keep the pace up.

        Flat (avoid) versus lively (aim for), as examples of tone only, not to copy:
        - Flat: "It's in five minutes." Lively: "Five minutes to go until your next meeting!"
        - Flat: "Over vijf minuten is het tijd voor de weekly." Lively: "Nog vijf minuten tot de weekly, dus rond maar af!"
        - Flat: "Je hebt om drie uur een afspraak met Sanne." Lively: "Om drie uur wacht Sanne al op je!"

        What the data means:
        - The previous song has just ended; the next one is already playing softly under your voice.
        - kind "leave": \(listener) has to leave (travel time). Say it's nearly time to go, not that the appointment starts.
        - kind "meeting": \(listener) doesn't have to go anywhere. Never say they have to leave or head out the door.
        - urgency "low": a relaxed heads-up. "medium": it's almost time.

        Extra style: energetic, dry sense of humour, now and then a wink at the song that just played.
        """
    }

    /// De gegevens als JSON, met alle tijden al uitgeschreven in de gekozen taal (geen cijfers).
    static func llmPayload(_ req: DJRequest, recent: [String] = [], lang: Language = .nl) -> String {
        struct Track: Codable { var title: String; var artist: String }
        struct Item: Codable {
            var title: String
            var kind: String
            var `in`: String
            var at: String
            var urgency: String
            var location: String?
            var description: String?
            var people: [String]?
        }
        struct Payload: Codable {
            var now: String
            var appointments: [Item]
            var previous_song: Track?
            var said_before: [String]?
        }
        let items = req.events.map { ev in
            let m = minutesUntil(ev, at: req.at)
            return Item(title: ev.title, kind: ev.travelMinutes > 0 ? "leave" : "meeting",
                        in: lang.minutes(m), at: lang.clock(ev.start),
                        urgency: m <= 5 ? "medium" : "low",
                        location: location(ev),
                        description: ev.notes.isEmpty ? nil : ev.notes,
                        people: ev.attendees.isEmpty ? nil : ev.attendees.map(firstName))
        }
        let track = req.previous.flatMap { $0.title.isEmpty ? nil : Track(title: $0.title, artist: $0.artist) }
        let payload = Payload(now: lang.clock(req.at), appointments: items, previous_song: track,
                              said_before: recent.isEmpty ? nil : recent)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: (try? enc.encode(payload)) ?? Data(), encoding: .utf8) ?? "{}"
    }
}
