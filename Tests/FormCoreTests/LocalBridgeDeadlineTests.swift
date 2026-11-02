import Foundation
import XCTest
@testable import FormCore

final class LocalBridgeDeadlineTests:XCTestCase {
  func testOnlyNativePNGExportsReceiveTheCaptureResponseWindow() {
    let id=UUID().uuidString
    let captures:[[String:Any]]=[
      ["format":"png"],["format":"png","object_id":id],
      ["format":"png","shot_id":id,"width":4096,"height":3072],
      ["format":"png","scene_id":id]]
    for arguments in captures {XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:arguments),180)}
    for format in ["pdf","svg","json","PNG","unknown"] {
      XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":format]),30)
    }
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:[:]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export_artwork",arguments:["format":"png"]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_status",arguments:[:]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_paper",arguments:["command":"configure","format":"png"]),30)
  }
  func testMultipagePublicationExportAndOnlyItsPreflightReceiveBoundedCompositionWindows() {
    let id=UUID().uuidString
    let exports:[[String:Any]]=[[:],["publication_id":id],["publication_id":id,"layout":"booklet","ink_output":"composite"],["publication_id":id,"layout":"spreads","ink_output":"preview"],["publication_id":id,"ink_output":"preflight"]]
    for arguments in exports {
      XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export_publication",arguments:arguments),600)
    }
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_publication",arguments:["command":"preflight","publication_id":id]),180)
    for command in ["get","spreads","create","settings","Preflight","unknown"] {
      XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_publication",arguments:["command":command,"publication_id":id]),30)
    }
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_publication",arguments:[:]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_publication",arguments:["command":true]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_story",arguments:["command":"preflight"]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_status",arguments:["command":"preflight"]),30)
  }
  func testSavedSceneVideoRetainsItsExistingBoundedWindow() {
    let id=UUID().uuidString
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4","scene_id":id]),600)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4"]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4","shot_id":id]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4","scene_id":NSNull()]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_status",arguments:["format":"mp4","scene_id":id]),30)
  }
}
