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

    func testCoordinatorOfGroup() {
        let state = """
        <ZoneGroupState><ZoneGroups>\
        <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:1"><ZoneGroupMember UUID="RINCON_A" Location="http://192.168.68.59:1400/xml/device_description.xml" ZoneName="Living Room"/></ZoneGroup>\
        <ZoneGroup Coordinator="RINCON_C" ID="RINCON_C:7"><ZoneGroupMember UUID="RINCON_B" Location="http://192.168.68.62:1400/xml/device_description.xml" ZoneName="Office"/>\
        <ZoneGroupMember UUID="RINCON_C" Location="http://192.168.68.58:1400/xml/device_description.xml" ZoneName="Office"/></ZoneGroup>\
        </ZoneGroups></ZoneGroupState>
        """
        XCTAssertEqual(SonosXML.coordinatorHost(forMemberHost: "192.168.68.62", inZoneGroupState: state), "192.168.68.58")
        XCTAssertEqual(SonosXML.coordinatorHost(forMemberHost: "192.168.68.59", inZoneGroupState: state), "192.168.68.59")
        XCTAssertNil(SonosXML.coordinatorHost(forMemberHost: "10.0.0.1", inZoneGroupState: state))
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
}
