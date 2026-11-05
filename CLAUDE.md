# DJ Agenda — ontwikkelnotities

Een macOS-menubalk-app (SwiftUI, Swift 6, macOS 15+) die Spotify laat klinken als een
radiostation. In de aanloop naar je volgende afspraak praat een DJ de laatste nummers aan elkaar.
Als de afspraak begint, zegt hij dat het tijd is en zet hij de muziek op pauze.

## Bouwen en testen

```sh
xcodebuild -project DJAgenda.xcodeproj -scheme DJAgenda -derivedDataPath build build
xcodebuild -project DJAgenda.xcodeproj -scheme DJAgenda -derivedDataPath build test
open build/Build/Products/Debug/DJAgenda.app
```

- **Plug-in "CudaBuild" vertrouwen.** De eerste keer moet je in Xcode de build-plug-in van
  mlx-swift vertrouwen: "Trust & Enable".
- **Metal-toolchain.** Voor MLX is de Metal-toolchain nodig:
  `xcodebuild -downloadComponent MetalToolchain`.
- **Ondertekenen.** `Signing.xcconfig` ondertekent standaard ad hoc. Een eigen team zet je in
  `Signing.local.xcconfig`; dat bestand staat in `.gitignore`.
- **Debug-opties** (alleen in Debug):
  - `--args -djTest announce`: test "Nu aankondigen";
  - `-djTest texts`: drie voorbeeldteksten en het slot in de log;
  - `-djTest demo -djDemoMinutes 5`: een nep-afspraak;
  - `-djOpenSettings`: opent bij het starten het instellingenvenster.
  - Elke instelling kun je ook meegeven, bijvoorbeeld `-language en`.
- **Logs:**
  `/usr/bin/log show --last 5m --info --predicate 'subsystem == "nl.rickpastoor.dj-agenda"'`.
  In zsh is `log` een ingebouwd commando, gebruik daarom het volledige pad.

## Release

- `scripts/release.sh 0.2` bouwt `build/release/DJAgenda-0.2.dmg`: archief (Release), export
  met Developer ID (team `ZCXSU9SYUC`), DMG, notarisatie en stapler.
  - Lokaal notariseren met een profiel: eenmalig
    `xcrun notarytool store-credentials notary --apple-id … --team-id ZCXSU9SYUC`, daarna
    `NOTARY_PROFILE=notary scripts/release.sh 0.2`. `SKIP_NOTARIZE=1` slaat het over.
  - Het script geeft `-skipPackagePluginValidation` mee, dus "Trust & Enable" is niet nodig.
- **CI:** `.github/workflows/release.yml`. Een tag `v0.2` pushen maakt een GitHub Release met de
  DMG. Handmatig starten (workflow_dispatch) levert alleen een artefact op. De secrets staan
  bovenin de workflow.

## Opbouw

| Bestand | Wat |
|---|---|
| `RadioLogic.swift` | De DJ-logica als pure struct: krijgt tijd, speler en afspraken, en geeft acties terug. Getest met een nep-klok en een nep-Spotify. |
| `AppModel.swift` | Lussen (agenda elke 60 s, DJ-ronde), klaarzetten en uitvoeren. Instellingen voor de UI. |
| `CalendarService.swift`, `AgendaEvent.swift` | EventKit en de filterregels. |
| `Output.swift`, `MacOutput.swift`, `SonosOutput.swift`, `SonosClient.swift`, `SonosClip.swift`, `AudioServer.swift` | Afspelen op de Mac (AppleScript) of de Sonos (UPnP + audioclip). |
| `DJText.swift`, `TextWriter.swift`, `DutchSpeech.swift`, `Language.swift` | De teksten: prompt, gegevens, controle, vaste zinnen. |
| `Voice.swift`, `VoxtralVoice.swift` | Stemmen (Voxtral cloud/lokaal, systeemstem), WAV en volume. |
| `MenuContent.swift`, `SettingsView.swift`, `Settings.swift`, `Keychain.swift` | Menu, instellingenvenster, UserDefaults, sleutels. |

## Aankondigingslogica

- **Geen muziek, geen DJ.** Alleen de knop "Nu aankondigen" praat altijd.
- **Aanloop**: vanaf `runUpMinutes` (12) voor de afspraak. AppleScript ziet de wachtrij niet, dus
  de aanloop wordt in minuten gerekend.
- **Bij elk nummer in de aanloop praat de DJ over de outro** (`talkOverLead`, 7 s voor het
  einde):
  - het volume gaat in 0,6 s omlaag en de DJ begint meteen;
  - het volgende nummer start onder zijn stem;
  - daarna komt het volume terug.
  - Tekst en audio worden 30 s van tevoren klaargezet.
- **Handmatig doorgeskipt** (nieuw track-id, positie < 6 s): dan praat de DJ over de intro. Na
  een aankondiging praat hij 45 s niet bij een wissel (`minGap`).
- **Slot**:
  - Begint de afspraak binnen `finalCutoffSeconds` (120 s) na het einde van het nummer, dan pauzeert
    de DJ op het einde (≤ 1 s) en zegt de slotzin.
  - Anders praat hij op het startmoment over de muziek heen en pauzeert daarna.
  - Muziek die hoogstens 1 minuut te laat start, krijgt alsnog het slot.
  - Daarna start de muziek niet vanzelf weer.
- **Reistijd**: het moment is `start − reistijd`, en het heet dan "vertrek".
- **Afspraken die binnen een minuut van elkaar beginnen**, gaan samen in één aankondiging.

## Agenda

- `requestFullAccessToEvents`. Standaard gebruikt de app alle agenda's; in de instellingen kies je
  er per account een aantal. Filteren gaat op titel én `source.title`, want agenda's heten vaak
  allebei "Calendar".
- Weglaten:
  - hele-dag-afspraken en geannuleerde afspraken;
  - afspraken die je zelf hebt afgeslagen;
  - titels met een trefwoord zoals "focus" of "lunch".
- Reistijd:
  - de private `travelTime`, alleen na `responds(to:)`, want een ObjC-exceptie kun je in Swift
    niet vangen;
  - anders een regel `reistijd: 12` in de notities.

## Afspelen

In de stand "auto" kijkt de app eerst of een Sonos speelt, en anders de Mac. Mislukt de Sonos,
dan probeert de app het pas na 5 minuten opnieuw.

**Mac: Spotify via `NSAppleScript`**
- De scripts draaien op een eigen seriële queue, want de TCC-melding blokkeert.
- Met de Nederlandse locale komt `player position` terug met een komma. `duration` is in ms.
- Het volume zakt soms een stapje na een fade; dat wordt na elke fade gecorrigeerd.

**Sonos: lokaal**
- **Status en besturing:** UPnP/SOAP op poort 1400 (AVTransport). Spotify Connect speelt op de
  groepscoördinator, en die vind je via `ZoneGroupTopology`.
- **Ontdekken:** Bonjour `_sonos._tcp`. Je kunt een kamernaam instellen, en een vast IP als
  terugval. Zonder kamer kiest de app de Sonos die speelt.
- **De DJ als audioclip** via `wss://<ip>:1443/websocket/api`, zoals het PyPI-pakket
  `sonos-websocket` doet. De Sonos zet de muziek zelf zachter.
  - Headers: `X-Sonos-Api-Key: 123e4567-e89b-12d3-a456-426655440000` en
    `Sec-WebSocket-Protocol: v1.api.smartspeaker.audio`.
  - Het certificaat is zelfondertekend en wordt alleen voor dat IP geaccepteerd.
  - De stappen:
    1. `[{}, {}]` geeft het `householdId`;
    2. `groups:1 getGroups`: kies de speler met dezelfde `websocketUrl` en controleer `AUDIO_CLIP`;
    3. `audioClip:1 loadAudioClip` met de `streamUrl`.
  - De app wacht zelf de duur van de clip af.
- **Audio serveren:** een kleine `NWListener`. De app neemt de eerste vrije poort vanaf 8765 en
  het eigen LAN-IP richting de Sonos.
- **Valkuilen:**
  - Een VPN met exitnode, zoals Tailscale, kan lokaal verkeer de tunnel in trekken. Bonjour werkt
    dan nog, maar TCP naar poort 1400 niet. Bij Tailscale zet je "Allow Local Network Access" aan.
  - Bij Spotify Connect is `TrackURI` (`x-sonos-vli:…`) voor elk nummer gelijk. Herken een nummer
    daarom aan titel, artiest en duur.

## Tekst

- **Standaard Mistral Large** (`mistral-large-latest`, temperature 0.8, `max_tokens` 200,
  timeout 10 s, ongeveer 2 s per tekst).
- **Optioneel:**
  - **Claude**: `claude-haiku-5-5`, `anthropic-version: 2026-10-21`, denken uit;
  - **het lokale Apple-model**: Foundation Models, macOS 26+, zwak in het Nederlands;
  - **vaste zinnen.**
- **Eén Engelse systeemprompt** (`DJText.llmSystem`) met "Write in Dutch/English" en de naam van
  de luisteraar ("Radio <naam>"). De toon is een energieke radiopresentator, met het aftellen
  voorop.
- **De gegevens** (`DJText.llmPayload`) zijn JSON met alle tijden al uitgeschreven ("zeven
  minuten", "half drie"), zonder cijfers.
- **De controle:** elke tekst moet de controle doorstaan: geen getallen die niet in de gegevens
  staan, tijdsduren die kloppen en geen herhaling. Hoogstens 3 pogingen, daarna een vaste zin.
- **De slotzin** is altijd een vaste zin.
- **Sleutels** staan in de Keychain (`dj-agenda-mistral`, `dj-agenda-anthropic`), of in
  `MISTRAL_API_KEY` / `ANTHROPIC_API_KEY`.
- **Privacy:** bij Mistral en Claude gaan titel, omschrijving en voornamen van de afspraak naar de
  API.

## Stem

1. **Voxtral via de Mistral-API (standaard)**: `POST /v1/audio/speech` met
   `voxtral-mini-tts-latest` en `ref_audio`. Duurt ongeveer 2 s voor 12 s audio.
   - De vaste Mistral-stemmen zijn Engels en werken niet met deze API. Daarom kloont de app een
     fragment van 10 s: `Resources/voice-{nl,en}-{male,female}.wav`.
   - Die fragmenten zijn gemaakt met de lokale Voxtral-stemmen `nl_male`, `nl_female`,
     `casual_male` en `cheerful_female`. Ze spreken een energieke radiotekst, want de kloon neemt
     de toon over.
2. **Voxtral lokaal**: via MLX met soniqo `VoxtralTTS` (speech-swift 0.0.29). Gebruikt ongeveer
   2,5 GB en loopt ongeveer realtime. Het model laadt alleen als je de lokale stem kiest, of na een
   mislukte cloudpoging.
3. **Laatste terugval**: `AVSpeechSynthesizer`.

- **Volume:** alle audio wordt WAV en wordt genormaliseerd op −20 dBFS (`Loudness`). De Engelse
  Voxtral-stemmen zijn van zichzelf zo'n 18 dB zachter.
- **Licentie:** Voxtral valt onder CC BY-NC (niet-commercieel), en dat geldt ook voor de
  stemfragmenten.
