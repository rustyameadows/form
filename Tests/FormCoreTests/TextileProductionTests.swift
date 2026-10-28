import Foundation
import XCTest
@testable import FormCore

final class TextileProductionTests:XCTestCase {
  private func fixture()throws -> (ProductionJobRevision,EmbroideryProgram) {
    var p=Project(name:"Measured needle paths"),object=try Project(name:"Object").makeObject(recipeID:"textilePatch",parameters:["width":80,"depth":60])
    let source=ArtworkElement(kind:"line",x:5,y:5,width:40,height:0.1)
    object.artwork=Artwork(elements:[source])
    var orange=StudioThread(name:"Orange",color:"#C75332");orange.availableMeters=1;orange.spoolMeters=1000;orange.spoolPrice=10;orange.currency="USD";orange.supplier="Declared test supplier";orange.sku="O-1"
    var blue=StudioThread(name:"Blue",color:"#285B8A");blue.spoolMeters=1000
    let design=EmbroideryDesign(threads:[.init(stock:orange),.init(stock:blue)],regions:[.init(elementIDs:[source.id],method:.running)])
    object.textile?.embroidery=design;p.objects=[object]
    let commands:[EmbroideryCommand]=[
      .init(.jump,x:100,y:100,threadIndex:0),.init(.stitch,x:100,y:100,threadIndex:0),
      .init(.stitch,x:130,y:140,threadIndex:0,purpose:.underlay),.init(.jump,x:-50,y:-50,threadIndex:0),
      .init(.stitch,x:-50,y:-50,threadIndex:0),.init(.stitch,x:-20,y:-10,threadIndex:0,purpose:.tieOff),
      .init(.colorChange,x:-20,y:-10,threadIndex:1),.init(.jump,x:0,y:0,threadIndex:1),
      .init(.stitch,x:0,y:0,threadIndex:1),.init(.stitch,x:0,y:50,threadIndex:1),.init(.end,x:0,y:50,threadIndex:1)]
    let program=EmbroideryProgram(name:"Measured",sourceDigest:String(repeating:"a",count:64),design:design,commands:commands);try program.validate()
    var assumptions=ProductionAssumptions();assumptions.upperThreadFactor=1.5;assumptions.allowanceMetersPerThreadPerItem=0.2;assumptions.baseUnitCost=2;assumptions.baseCurrency="USD";assumptions.laborMinutesPerItem=5;assumptions.hourlyLaborRate=30;assumptions.laborCurrency="USD"
    let revision=ProductionJobRevision(object:object,material:p.material(object.materialID),quantity:10,outputs:["dst","svg","json"],assumptions:assumptions,program:program,programDigest:String(repeating:"b",count:64),equipment:nil)
    return (revision,program)
  }
  func testMeasuredNeedleLengthIncludesUnderlayAndLocksAndExcludesTravel()throws {
    let (_,program)=try fixture(),usage=ThreadNeedleUsage.measure(program)
    XCTAssertEqual(usage.count,2)
    XCTAssertEqual(usage[0].needleMeters,0.010,accuracy:1e-12);XCTAssertEqual(usage[0].underlayMeters,0.005,accuracy:1e-12);XCTAssertEqual(usage[0].tieMeters,0.005,accuracy:1e-12);XCTAssertEqual(usage[0].stitches,4)
    XCTAssertEqual(usage[1].needleMeters,0.005,accuracy:1e-12)
  }
  func testUnknownConsumptionCostsAndMixedCurrenciesNeverBecomeInventedZeros()throws {
    var (revision,_)=try fixture();try revision.validate()
    let before=revision.object.textile!.embroidery!.threads[0].stock!.availableMeters
    let partial=ProductionCostEstimate.estimate(revision)
    XCTAssertEqual(partial.threads[0].measuredNeedleMeters,0.1,accuracy:1e-12)
    XCTAssertEqual(partial.threads[0].estimatedMeters!,2.15,accuracy:1e-12);XCTAssertEqual(partial.threads[0].estimatedCost!,0.0215,accuracy:1e-12)
    XCTAssertEqual(partial.threads[0].stockSufficient,false);XCTAssertNil(partial.threads[1].stockSufficient)
    XCTAssertNil(partial.total);XCTAssertEqual(partial.knownSubtotals["USD"]!,45.0215,accuracy:1e-10)
    XCTAssertEqual(revision.object.textile!.embroidery!.threads[0].stock!.availableMeters,before)
    revision.object.textile!.embroidery!.threads[1].stock!.spoolPrice=20;revision.object.textile!.embroidery!.threads[1].stock!.currency="USD"
    let complete=ProductionCostEstimate.estimate(revision)
    XCTAssertEqual(complete.total!,45.063,accuracy:1e-10);XCTAssertTrue(complete.unknowns.isEmpty)
    revision.object.textile!.embroidery!.threads[1].stock!.currency="EUR"
    let mixed=ProductionCostEstimate.estimate(revision);XCTAssertNil(mixed.total);XCTAssertEqual(mixed.knownSubtotals.count,2);XCTAssertTrue(mixed.unknowns.contains {$0.contains("Mixed currencies")})
    revision.assumptions.upperThreadFactor=nil
    let unknown=ProductionCostEstimate.estimate(revision);XCTAssertNil(unknown.threads[0].estimatedMeters);XCTAssertNil(unknown.threads[0].estimatedCost)
    revision.assumptions=ProductionAssumptions();let blank=ProductionCostEstimate.estimate(revision)
    XCTAssertTrue(blank.knownSubtotals.isEmpty);XCTAssertNil(blank.total);XCTAssertNil(blank.currency)
    var (shared,_)=try fixture()
    var sameStock=shared.object.textile!.embroidery!.threads[0].stock!;sameStock.availableMeters=3
    shared.object.textile!.embroidery!.threads=[.init(stock:sameStock),.init(stock:sameStock)]
    let combined=ProductionCostEstimate.estimate(shared)
    XCTAssertEqual(combined.threads.map(\.stockSufficient),[false,false])
    shared.object.textile!.embroidery!.threads[1].stock!.availableMeters=4
    let conflict=ProductionCostEstimate.estimate(shared)
    XCTAssertTrue(conflict.threads.allSatisfy {$0.stockSufficient==nil});XCTAssertTrue(conflict.inventoryNotes.contains {$0.contains("conflicting")})
  }
  func testDeclaredEquipmentChecksAxesAndFormatWithoutGuessingMachineState()throws {
    let (revision,_)=try fixture(),design=revision.object.textile!.embroidery!
    XCTAssertEqual(EmbroideryCompatibility.check(design:design,equipment:nil,outputs:["dst"]).status,.unknown)
    var equipment=EmbroideryEquipment(name:"Declared single-needle machine");equipment.needleCount=1
    XCTAssertEqual(EmbroideryCompatibility.check(design:design,equipment:equipment,outputs:["dst"]).status,.unknown)
    equipment.hoops=[.init(name:"100 mm",width:100,height:100)];equipment.formats=["dst"]
    let covered=EmbroideryCompatibility.check(design:design,equipment:equipment,outputs:["dst","svg"])
    XCTAssertEqual(covered.status,.declaredCompatible);XCTAssertTrue(covered.messages.contains {$0.contains("Unverified")})
    equipment.hoops=[.init(name:"Different axes",width:150,height:90)]
    XCTAssertEqual(EmbroideryCompatibility.check(design:design,equipment:equipment,outputs:["dst"]).status,.incompatible)
    equipment.hoops=[.init(name:"100 mm",width:100,height:100)];equipment.formats=["pes"]
    XCTAssertEqual(EmbroideryCompatibility.check(design:design,equipment:equipment,outputs:["dst"]).status,.incompatible)
    XCTAssertEqual(EmbroideryCompatibility.check(design:design,equipment:equipment,outputs:["svg"]).status,.unknown)
  }
  func testPortableStockIdentityValidatesAndLegacyLibraryKeepsUnknowns()throws {
    let legacy=try JSONDecoder.form.decode(StudioLibrary.self,from:Data("{}".utf8))
    XCTAssertNil(legacy.textileProduction)
    var stock=StudioThread(name:"Studio spool",color:"#447799");XCTAssertNil(stock.pricePerMeter);try stock.validate()
    stock.spoolPrice=10;XCTAssertThrowsError(try stock.validate())
    stock.currency="USD";try stock.validate();XCTAssertNil(stock.pricePerMeter)
    stock.spoolMeters=1000;XCTAssertEqual(stock.pricePerMeter,0.01)
    var thread=EmbroideryThread(stock:stock),design=EmbroideryDesign(threads:[thread],regions:[.init(elementIDs:[UUID()],method:.running)])
    try design.validate();thread.color="#FFFFFF";design.threads=[thread];XCTAssertThrowsError(try design.validate())
    var p=Project(name:"Portable stock"),object=try p.makeObject(recipeID:"textilePatch")
    object.textile?.embroidery=EmbroideryDesign(threads:[.init(stock:stock)],regions:[.init(elementIDs:[UUID()],method:.running)]);p.objects=[object]
    XCTAssertEqual(p.minimumSchemaVersion,29)
    stock.availableMeters = -.infinity;XCTAssertThrowsError(try stock.validate())
  }
  func testUserQualityRecordsRemainRevisionLinkedAndLineageRejectsCycles()throws {
    let hash=String(repeating:"a",count:64)
    var job=ProductionJob(name:"Sample",objectID:UUID(),sourceDigest:hash,revisionDigest:String(repeating:"b",count:64),programDigest:String(repeating:"c",count:64),quantity:1)
    var record=ProductionRecord(kind:.quality,sourceDigest:hash,notes:"User reports a clean sample on twill.");record.outcome = .pass;record.reportedMeters=1.2
    job.records=[record];try job.validate();XCTAssertEqual(job.status,.planned)
    var status=ProductionRecord(kind:.status,sourceDigest:hash,notes:"User approves this captured sample.");status.status = .approved;job.records.append(status);try job.validate();XCTAssertEqual(job.status,.approved)
    record.sourceDigest=String(repeating:"d",count:64);XCTAssertThrowsError(try record.validate(source:hash))
    var p=Project(name:"Lineage");p.productionJobs=[job];try p.validateProductionJobs()
    var next=job;next.id=UUID();next.supersedesJobID=job.id;p.productionJobs!.append(next);try p.validateProductionJobs()
    p.productionJobs![0].supersedesJobID=next.id;XCTAssertThrowsError(try p.validateProductionJobs())
    var assumptions=ProductionAssumptions();assumptions.upperThreadFactor=0.5;XCTAssertThrowsError(try assumptions.validate())
  }
}
