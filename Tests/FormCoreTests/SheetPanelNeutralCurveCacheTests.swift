import Foundation
import XCTest
@testable import FormCore

final class SheetPanelNeutralCurveCacheTests:XCTestCase {
  private let controls:[Point2]=[.init(0,0),.init(-1.375,0),.init(-1.375,24.671),.init(8.193,24.671)]
  func testIdenticalNumericalProfilesAvoidRepeatedSolvesAndStillCheckEveryCaliper()throws {
    let width=73.28419,before=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    let first=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true,maximumNormalOffsetMM:0.1)
    let warm=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    let started=Date.timeIntervalSinceReferenceDate
    for _ in 0..<32 {
      let profile=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true,maximumNormalOffsetMM:0.15)
      XCTAssertEqual(profile,first)
    }
    for invalid in [-0.1,Double.nan,first.minimumRadiusMM] {
      XCTAssertThrowsError(try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true,maximumNormalOffsetMM:invalid))
    }
    let after=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    XCTAssertEqual(after.solves,warm.solves,"Warm resolutions and caliper rejections must not rerun the neutral-curve solver.")
    XCTAssertGreaterThanOrEqual(after.hits-warm.hits,35)
    print("NEUTRAL_CURVE_CACHE cold_solves=\(warm.solves-before.solves) cold_solve_ms=\(warm.solveMilliseconds-before.solveMilliseconds) warm_resolutions=35 warm_ms=\((Date.timeIntervalSinceReferenceDate-started)*1000)")
  }
  func testExactNumericWidthEveryControlCoordinateAndFitFlagParticipateInTheKey()throws {
    let width=79.16358
    let first=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true)
    let before=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    let wider=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width+0.001,fitLength:true)
    XCTAssertNotEqual(wider.points,first.points);XCTAssertEqual(wider.lengthMM,width+0.001,accuracy:1e-6)
    var changed=controls;changed[2].y += 0.125
    let other=try SheetPanelNeutralCurveProfile(points:changed,widthMM:width,fitLength:true)
    XCTAssertNotEqual(other.sample(atMM:width*0.4),first.sample(atMM:width*0.4))
    changed=controls;changed[3].x += 0.25
    let endpoint=try SheetPanelNeutralCurveProfile(points:changed,widthMM:width,fitLength:true)
    XCTAssertEqual(endpoint.sample(atMM:width).xMM,controls[3].x+0.25,accuracy:1e-7)
    XCTAssertGreaterThanOrEqual(SheetPanelNeutralCurveProfile.resolutionCacheUsage.solves-before.solves,3)
    XCTAssertThrowsError(try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:false),
      "A fitted cache entry must not bypass the supplied-length check when fitting is disabled.")
    // Two finite numeric controls separated by one ULP must not be rounded into
    // one key, even when their visual difference is subpixel.
    let numericBefore=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    changed=controls;changed[1].x=changed[1].x.nextUp
    _=try SheetPanelNeutralCurveProfile(points:changed,widthMM:width,fitLength:true)
    XCTAssertGreaterThan(SheetPanelNeutralCurveProfile.resolutionCacheUsage.solves,numericBefore.solves)
  }
  private final class Results:@unchecked Sendable {
    private let lock=NSLock()
    private var profiles=[SheetPanelNeutralCurveProfile](),errors=[String]()
    func record(_ profile:SheetPanelNeutralCurveProfile){lock.lock();profiles.append(profile);lock.unlock()}
    func fail(_ error:Error){lock.lock();errors.append(error.localizedDescription);lock.unlock()}
    var snapshot:(profiles:[SheetPanelNeutralCurveProfile],errors:[String]) {lock.lock();defer{lock.unlock()};return(profiles,errors)}
  }
  func testConcurrentReadersRetainIdenticalImmutableProfilesAndBoundedCache()throws {
    let controls=self.controls,width=83.47291,sink=Results()
    let expected=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true,maximumNormalOffsetMM:0.2)
    let before=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    DispatchQueue.concurrentPerform(iterations:64) {index in
      do {sink.record(try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true,maximumNormalOffsetMM:index%2==0 ? 0.1:0.2))}
      catch{sink.fail(error)}
    }
    let results=sink.snapshot
    XCTAssertTrue(results.errors.isEmpty,results.errors.joined(separator:"; "));XCTAssertEqual(results.profiles.count,64)
    XCTAssertTrue(results.profiles.allSatisfy{$0==expected})
    let after=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    XCTAssertEqual(after.solves,before.solves);XCTAssertGreaterThanOrEqual(after.hits-before.hits,64)
    XCTAssertLessThanOrEqual(after.entries,128)
    let changed=Results()
    DispatchQueue.concurrentPerform(iterations:12) {index in
      do {let profile=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width+Double(index+1)*0.01,fitLength:true);changed.record(profile)}
      catch{changed.fail(error)}
    }
    XCTAssertTrue(changed.snapshot.errors.isEmpty);XCTAssertEqual(changed.snapshot.profiles.count,12)
    XCTAssertLessThanOrEqual(SheetPanelNeutralCurveProfile.resolutionCacheUsage.entries,128)
  }
  func testCacheEvictsNumericalShapesWithoutRetainingAnUnboundedKeyHistory()throws {
    let controls=self.controls,width=97.38127
    let original=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true)
    for index in 0..<132 {
      let w=1.371+Double(index)*0.011
      _=try SheetPanelNeutralCurveProfile(points:[.init(0,0),.init(w/3,0),.init(2*w/3,0),.init(w,0)],widthMM:w)
    }
    let full=SheetPanelNeutralCurveProfile.resolutionCacheUsage
    XCTAssertEqual(full.maximumEntries,128);XCTAssertEqual(full.entries,128)
    let recovered=try SheetPanelNeutralCurveProfile(points:controls,widthMM:width,fitLength:true)
    XCTAssertEqual(recovered,original)
    XCTAssertGreaterThan(SheetPanelNeutralCurveProfile.resolutionCacheUsage.solves,full.solves,"An evicted shape must be recomputed from its actual controls.")
    XCTAssertEqual(SheetPanelNeutralCurveProfile.resolutionCacheUsage.entries,128)
  }
}
