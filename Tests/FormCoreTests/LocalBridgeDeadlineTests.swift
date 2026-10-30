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
  func testSavedSceneVideoRetainsItsExistingBoundedWindow() {
    let id=UUID().uuidString
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4","scene_id":id]),600)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4"]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4","shot_id":id]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_export",arguments:["format":"mp4","scene_id":NSNull()]),30)
    XCTAssertEqual(LocalBridgeClient.responseTimeoutSeconds(for:"form_status",arguments:["format":"mp4","scene_id":id]),30)
  }
}
