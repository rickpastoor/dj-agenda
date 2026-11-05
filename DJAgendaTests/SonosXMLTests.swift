import XCTest
@testable import DJAgenda

final class SonosXMLTests: XCTestCase {
    func testPositionInfoAndMetadata() {
        let xml = """
        <s:Envelope><s:Body><u:GetPositionInfoResponse><Track>1</Track><TrackDuration>0:03:35</TrackDuration>\
        <TrackMetaData>&lt;DIDL-Lite&gt;&lt;item&gt;&lt;dc:title&gt;Rock &amp;amp; Roll&lt;/dc:title&gt;\
        &lt;dc:creator&gt;Led Zeppelin&lt;/dc:creator&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData>\
        <TrackURI>x-sonos-spotify:spotify%3atrack%3aabc?sid=9&amp;flags=8224</TrackURI><RelTime>0:01:02</RelTime>\
        </u:GetPositionInfoResponse></s:Body></s:Envelope>
        """
        XCTAssertEqual(SonosXML.seconds(SonosXML.value("TrackDuration", in: xml)), 215)
        XCTAssertEqual(SonosXML.seconds(SonosXML.value("RelTime", in: xml)), 62)
        XCTAssertEqual(SonosXML.seconds("NOT_IMPLEMENTED"), 0)
        let meta = SonosXML.unescape(SonosXML.value("TrackMetaData", in: xml)!)
        XCTAssertEqual(SonosXML.unescape(SonosXML.value("dc:title", in: meta)!), "Rock & Roll")
        XCTAssertEqual(SonosXML.value("dc:creator", in: meta), "Led Zeppelin")
        XCTAssertEqual(SonosXML.unescape(SonosXML.value("TrackURI", in: xml)!),
                       "x-sonos-spotify:spotify%3atrack%3aabc?sid=9&flags=8224")
    }

    /// De indeling zoals die bij Rick thuis staat: een Beam, een stereopaar en een groep van vier.
    static let house = """
    <ZoneGroupState><ZoneGroups>\
    <ZoneGroup Coordinator="RINCON_BEAM" ID="RINCON_BEAM:1"><ZoneGroupMember UUID="RINCON_BEAM" Location="http://192.168.68.78:1400/xml/device_description.xml" ZoneName="Beam"><Satellite UUID="RINCON_SUB" Location="http://192.168.68.90:1400/xml/device_description.xml" ZoneName="Beam" Invisible="1"/></ZoneGroupMember></ZoneGroup>\
    <ZoneGroup Coordinator="RINCON_OFF1" ID="RINCON_OFF1:2"><ZoneGroupMember UUID="RINCON_OFF1" Location="http://192.168.68.62:1400/xml/device_description.xml" ZoneName="Office"/>\
    <ZoneGroupMember UUID="RINCON_OFF2" Location="http://192.168.68.58:1400/xml/device_description.xml" ZoneName="Office" Invisible="1"/></ZoneGroup>\
    <ZoneGroup Coordinator="RINCON_LIV" ID="RINCON_LIV:3"><ZoneGroupMember UUID="RINCON_DIN" Location="http://192.168.68.67:1400/xml/device_description.xml" ZoneName="Dining Room"/>\
    <ZoneGroupMember UUID="RINCON_DIN2" Location="http://192.168.68.56:1400/xml/device_description.xml" ZoneName="Dining Room 2"/>\
    <ZoneGroupMember UUID="RINCON_LIV" Location="http://192.168.68.59:1400/xml/device_description.xml" ZoneName="Living Room"/>\
    <ZoneGroupMember UUID="RINCON_KIT" Location="http://192.168.68.68:1400/xml/device_description.xml" ZoneName="Kitchen"/></ZoneGroup>\
    </ZoneGroups></ZoneGroupState>
    """

    func testGroups() {
        let groups = SonosXML.groups(inZoneGroupState: Self.house)
        XCTAssertEqual(groups.map(\.name), ["Beam", "Office", "Living Room + 3"])
        XCTAssertEqual(groups.map(\.coordinatorHost), ["192.168.68.78", "192.168.68.62", "192.168.68.59"])
        XCTAssertEqual(groups[0].members.count, 1, "Satellieten tellen niet mee")
        XCTAssertEqual(groups[1].visibleMembers.map(\.host), ["192.168.68.62"], "Stereopaar: één kamer")
        XCTAssertEqual(groups[2].visibleMembers.count, 4)
    }

    @MainActor
    func testPickPlayingGroup() {
        let g = SonosXML.groups(inZoneGroupState: Self.house)
        let pick = { (playing: Set<String>, current: String?) in
            SonosOutput.pick(g, playing: playing, current: current)?.name
        }
        // De muziek verhuist van de Beam naar de woonkamer: volgen.
        XCTAssertEqual(pick(["RINCON_LIV"], "RINCON_BEAM"), "Living Room + 3")
        // Twee groepen spelen: blijf bij de groep van nu.
        XCTAssertEqual(pick(["RINCON_LIV", "RINCON_OFF1"], "RINCON_OFF1"), "Office")
        // Niets speelt: de groep van nu.
        XCTAssertEqual(pick([], "RINCON_LIV"), "Living Room + 3")
        // Nog geen groep en niets speelt: de eerste op naam.
        XCTAssertEqual(pick([], nil), "Beam")
    }

    @MainActor
    func testTVIsNotMusic() {
        XCTAssertTrue(SonosOutput.playsMusic(state: "PLAYING", uri: "x-sonos-vli:RINCON_LIV:2,spotify:abc"))
        XCTAssertFalse(SonosOutput.playsMusic(state: "PLAYING", uri: "x-sonos-htastream:RINCON_BEAM:spdif"))
        XCTAssertFalse(SonosOutput.playsMusic(state: "PAUSED_PLAYBACK", uri: "x-sonos-vli:RINCON_LIV:2,spotify:abc"))
    }

    @MainActor
    func testSpotifyConnectTrackIDChangesPerTrack() {
        let vli = "x-sonos-vli:RINCON_542A1B94056C01400:2,spotify:867fba2cc98ad20aa633fdaef7e8b343"
        let a = SonosOutput.trackID(uri: vli, title: "Dreams", artist: "Fleetwood Mac", duration: 257)
        let b = SonosOutput.trackID(uri: vli, title: "Africa", artist: "Toto", duration: 295)
        XCTAssertNotEqual(a, b, "Zelfde sessie-URI, ander nummer")
        XCTAssertEqual(SonosOutput.trackID(uri: "x-file-cifs://nas/a.mp3", title: "x", artist: "y", duration: 1),
                       "x-file-cifs://nas/a.mp3")
    }

    func testClipVolumeFollowsMusic() {
        XCTAssertEqual(SonosOutput.clipVolume(music: 10, boost: 3), 13)
        XCTAssertEqual(SonosOutput.clipVolume(music: 2, boost: -5), 3, "Nooit onhoorbaar")
        XCTAssertEqual(SonosOutput.clipVolume(music: 90, boost: 10), 70, "Nooit keihard")
        XCTAssertEqual(SonosOutput.clipVolume(music: nil, boost: 3), 20)
    }
}
