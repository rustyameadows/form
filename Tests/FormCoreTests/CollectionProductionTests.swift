import XCTest
@testable import FormCore

final class CollectionProductionTests:XCTestCase {
  func testStrictDecimalRejectsPartialNonfinitePrecisionLossAndOverflow()throws {
    for value in ["1x"," 1","1 ","+1","-1","1e2","NaN","Infinity","0.1234567890123","1000000000001","00.1","1."] {XCTAssertThrowsError(try CollectionDecimal.parse(value),value)}
    XCTAssertEqual(try CollectionDecimal.string(CollectionDecimal.parse("12.3400")),"12.34")
    XCTAssertThrowsError(try CollectionDecimal.currency("USD\n"))
    XCTAssertEqual(try CollectionDecimal.computed(0.04),"0.04")
    XCTAssertThrowsError(try CollectionDecimal.computed(1e-300))
    XCTAssertThrowsError(try CollectionDecimal.multiply(CollectionDecimal.resolved("1000000000000000000"),Decimal(2)))
    XCTAssertThrowsError(try CollectionDecimal.divide(Decimal(1),Decimal(3)))
    XCTAssertEqual(try CollectionDecimal.product("0.1","3"),"0.3")
    XCTAssertEqual(try CollectionDecimal.sum(["0.1","0.2"]),"0.3")
  }
  func testReportedDivisionUsesExactIntegerHalfEvenAndRecordsCommonLabor()throws {
    let third=try CollectionDecimal.estimateDivision(1,3,inputs:["example":"1/3"])
    XCTAssertEqual(third.result,"0.333333333333");XCTAssertTrue(third.rounded);XCTAssertEqual(third.policyVersion,1);XCTAssertEqual(third.originalInputs,["example":"1/3"])
    let labor=try CollectionDecimal.estimateDivision(10,60,inputs:["minutes":"1","hourly_rate":"10"])
    XCTAssertEqual(labor.result,"0.166666666667");XCTAssertTrue(labor.rounded)
    let exact=try CollectionDecimal.estimateDivision(1,2,inputs:[:]);XCTAssertEqual(exact.result,"0.5");XCTAssertFalse(exact.rounded)
    let even=try CollectionDecimal.estimateDivision(1,Decimal(string:"2000000000000")!,inputs:[:]);XCTAssertEqual(even.result,"0");XCTAssertTrue(even.rounded)
    let odd=try CollectionDecimal.estimateDivision(3,Decimal(string:"2000000000000")!,inputs:[:]);XCTAssertEqual(odd.result,"0.000000000002")
  }
  func testCSVNeutralizesHumanFormulaPrefixesAndQuotesWithoutChangingJSON()throws {
    for s in ["=1+1","  +cmd","-2+3","@SUM(A1)","\tplain","\n=bad","\u{200B}=1","\u{FEFF}+1","\u{00A0}@SUM(A1)"] {XCTAssertTrue(CollectionDecimal.csv(s).hasPrefix("\"'"))}
    XCTAssertEqual(CollectionDecimal.csv("a,\"b\""),"\"a,\"\"b\"\"\"")
    let original="=IMPORT(\"x\")";XCTAssertEqual(try JSONDecoder().decode(String.self,from:JSONEncoder().encode(original)),original)
  }
  func testNASABomberRunCountsAttachedDetailsAndExplicitSparesExactlyOnce()throws {
    let p=Samples.flightJacket(),roots=p.objects.filter{$0.textile?.kind == .garment},loose=p.objects.filter{$0.textile != nil && $0.textile?.kind != .garment && $0.textile?.attachment==nil}
    XCTAssertEqual(p.objects.count,15);XCTAssertEqual(roots.count,2);XCTAssertEqual(loose.count,2)
    let plan=CollectionProductionPlan(name:"ORBITAL production",runs:[.init(objectID:roots[0].id,quantity:12),.init(objectID:roots[1].id,quantity:8),.init(objectID:loose.first{$0.textile?.kind == .patch}!.id,quantity:6),.init(objectID:loose.first{$0.textile?.kind == .label}!.id,quantity:4)])
    let before=try JSONEncoder.form.encode(p)
    let scope=try CollectionQuantities.scope(plan,project:p)
    XCTAssertEqual(scope.occurrences.reduce(0){$0+$1.quantity},110)
    XCTAssertEqual(scope.occurrences.filter{$0.parentID != nil}.reduce(0){$0+$1.quantity},80)
    XCTAssertFalse(scope.occurrences.contains{$0.objectID.map{id in p.objects.first{$0.id==id}?.recipeID=="artboard"} ?? false})
    let report=try CollectionEstimate.evaluate(plan,scope:scope);XCTAssertNil(report.completeTotal);XCTAssertFalse(report.unknowns.isEmpty);XCTAssertTrue(report.rows.filter{$0.role=="specification"}.allSatisfy{$0.quantity==nil})
    XCTAssertEqual(try JSONEncoder.form.encode(p),before)
  }
  func testAmbiguousAttachmentAndSourceRootRejectWithoutMutatingSource()throws {
    let p=Samples.flightJacket(),j=p.objects.first{$0.textile?.kind == .garment}!,a=p.objects.first{$0.textile?.attachment?.garmentID==j.id}!
    XCTAssertThrowsError(try CollectionQuantities.scope(.init(name:"duplicate",runs:[.init(objectID:j.id),.init(objectID:a.id)]),project:p))
    XCTAssertThrowsError(try CollectionQuantities.scope(.init(name:"source",runs:[.init(objectID:p.objects.first{$0.recipeID=="artboard"}!.id)]),project:p))
  }
  func testMixedCurrencyUnknownAndSharedStockAreExplicit()throws {
    let p=Samples.flightJacket(),o=p.objects.first{$0.textile?.kind == .garment}!,run=CollectionRun(objectID:o.id,quantity:2,includeAttachments:false)
    var plan=CollectionProductionPlan(name:"Declared",runs:[run]);var first=CollectionExtraLine(name:"Zip",unit:.piece);first.quantity="1";first.runID=run.id;first.unitPrice="2.25";first.currency="USD"
    var second=CollectionExtraLine(name:"Trim",unit:.piece);second.quantity="3";second.unitPrice="1";second.currency="EUR";plan.extras=[first,second]
    var stock=StudioSupply(name:"Shared trim");stock.available="4";stock.unitPrice="1";stock.currency="USD"
    var a=CollectionLineRule(rowID:"extra/"+first.id.uuidString);a.stock = .init(supply:stock)
    var b=CollectionLineRule(rowID:"extra/"+second.id.uuidString);b.stock = .init(supply:stock);plan.rules=[a,b]
    var report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p));XCTAssertEqual(report.stock.count,1);XCTAssertEqual(report.stock[0].knownDemand,"5");XCTAssertEqual(report.stock[0].status,"insufficient");XCTAssertEqual(report.knownSubtotals,["USD":"4.5","EUR":"3"]);XCTAssertNil(report.completeTotal)
    stock.available="6";plan.rules[1].stock = .init(supply:stock)
    report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p));XCTAssertEqual(report.stock[0].status,"conflict");XCTAssertNil(report.stock[0].available)
    plan.rules=[];report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p));XCTAssertEqual(report.knownSubtotals,["USD":"4.5","EUR":"3"])
  }
  func testCollectionSchemaAndSourceDigestIgnoreCameraHistoryAndArchiveList()throws {
    var p=Samples.flightJacket();let plan=CollectionProductionPlan(name:"Capture",runs:[.init(objectID:p.objects[0].id)])
    let original=try CollectionSource(project:p,plan:plan).data();p.camera.distance += 1;p.history.append(.init("Unrelated history"));p.collectionProduction = .init();p.collectionProduction?.plans=[plan]
    XCTAssertEqual(try CollectionSource(project:p,plan:plan).data(),original);XCTAssertEqual(p.minimumSchemaVersion,45)
    let reopened=try JSONDecoder.form.decode(Project.self,from:JSONEncoder.form.encode(p));XCTAssertEqual(reopened.collectionProduction?.plans,[plan])
    p.objects[0].name += " changed";XCTAssertNotEqual(try CollectionSource(project:p,plan:plan).data(),original)
  }
  func testSavedShotsAreNotPhysicalCollectionSourceAndOpticalTypographyStillIs()throws {
    var p=Project(name:"Physical source versus presentation")
    var owner=try p.makeObject(recipeID:"artboard")
    var text=ArtworkElement(kind:"text",x:5,y:5,width:80,height:20,text:"H₂O — original words")
    text.typography = .init();text.typography?.opticalSizing = .init(.automatic)
    owner.artwork=Artwork(elements:[text]);p.objects=[owner]
    let plan=CollectionProductionPlan(name:"Source",runs:[.init(objectID:owner.id)])
    let original=try CollectionSource(project:p,plan:plan).data()
    let originalStudio=try p.studioDesignDigest()
    var shot=StudioShot(name:"A new saved composition",camera:p.camera,referenceAspect:1.5)
    shot.pixels = .init(width:813,height:555);p.studioPresentation = .init(shots:[shot])
    p.schemaVersion=45;p.camera.distance=19;p.history.append(.init("Saved presentation"))
    XCTAssertEqual(try CollectionSource(project:p,plan:plan).data(),original)
    p.studioPresentation?.shots[0].name="Renamed without a source change"
    p.studioPresentation?.shots[0].lighting="soft-side-v1"
    p.collectionProduction = .init();p.collectionProduction?.plans=[plan]
    XCTAssertEqual(try CollectionSource(project:p,plan:plan).data(),original)
    XCTAssertEqual(try p.studioDesignDigest(),originalStudio)
    p.objects[0].artwork?.elements[0].typography?.opticalSizing = .init(.none)
    XCTAssertNotEqual(try CollectionSource(project:p,plan:plan).data(),original)
    XCTAssertNotEqual(try p.studioDesignDigest(),originalStudio)
    XCTAssertEqual(p.objects[0].artwork?.elements[0].text,text.text)
    XCTAssertEqual(p.objects[0].artwork?.elements[0].fontSize,text.fontSize)
    let beforePosition=try CollectionSource(project:p,plan:plan).data(),studioBeforePosition=try p.studioDesignDigest()
    p.objects[0].artwork?.elements[0].typography?.characterPosition = .superscript
    let positioned=try CollectionSource(project:p,plan:plan)
    XCTAssertEqual(positioned.project.objects[0].artwork?.elements[0].typography?.characterPosition,.superscript)
    XCTAssertEqual(positioned.project.objects[0].artwork?.elements[0].text,text.text)
    XCTAssertEqual(positioned.project.objects[0].artwork?.elements[0].fontSize,text.fontSize)
    XCTAssertEqual(positioned.project.minimumSchemaVersion,47)
    XCTAssertNotEqual(try positioned.data(),beforePosition)
    XCTAssertNotEqual(try p.studioDesignDigest(),studioBeforePosition)
    p.objects[0].artwork?.elements[0].typography?.characterPosition=nil
    XCTAssertEqual(try CollectionSource(project:p,plan:plan).data(),beforePosition)
    XCTAssertEqual(try p.studioDesignDigest(),studioBeforePosition)
  }
  func testManagedThreeSizeSourceHasExactElasticLapOnceAndActualCutGeometry()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));var p=Project(name:"Ground systems");let owner=try p.ensureCanvasWorkspace();engine.project=p
    _ = try engine.call("form_edit_artwork",arguments:["object_id":owner.id.uuidString,"command":"garment_block","operation":"create"])
    p=engine.project!;let block=p.garmentBlocks![0],before=try JSONEncoder.form.encode(p)
    let plan=CollectionProductionPlan(name:"Original three-size run",runs:block.sizes.map{.init(blockID:block.id,sizeID:$0.id)})
    let report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p)),elastic=report.rows.filter{$0.role=="trim"}
    XCTAssertEqual(elastic.compactMap(\.quantity),["0.725","0.765","0.805"]);XCTAssertEqual(try CollectionDecimal.sum(elastic.compactMap(\.quantity)),"2.295")
    XCTAssertEqual(report.occurrences.count,3);XCTAssertEqual(report.rows.filter{$0.role=="geometry"}.count,6);XCTAssertNil(report.completeTotal)
    XCTAssertTrue(report.rows.filter{$0.role=="material"}.allSatisfy{$0.quantity==nil})
    let expected=[(550.0,708.0),(570.0,718.0),(590.0,728.0)]
    for (index,size) in block.sizes.enumerated(){let ref=block.bindings.first{$0.sizeID==size.id && $0.role == .front}!,art=p.objects.first{$0.id==ref.objectID}!.artwork!,e=art.elements.first{$0.id==ref.elementID}!,g=try SewingPatterns.geometry(e,in:art);XCTAssertEqual(g.bounds.width,expected[index].0);XCTAssertEqual(g.bounds.height,expected[index].1)}
    XCTAssertEqual(try JSONEncoder.form.encode(p),before)
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"] {let out=URL(fileURLWithPath:folder).appendingPathComponent("Managed");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true);try before.write(to:out.appendingPathComponent("Source.json"));try JSONEncoder.form.encode(plan).write(to:out.appendingPathComponent("Plan.json"));try JSONEncoder.form.encode(report).write(to:out.appendingPathComponent("BOM.json"))}
    let ref=block.bindings.first{$0.role == .elastic}!,o=p.objects.firstIndex{$0.id==ref.objectID}!,e=p.objects[o].artwork!.elements.firstIndex{$0.id==ref.elementID}!
    p.objects[o].artwork!.elements[e].width+=1
    let stale=try CollectionQuantities.scope(plan,project:p);XCTAssertTrue(stale.lines.contains{$0.id.contains("elastic") && $0.quantity==nil});XCTAssertFalse(stale.findings.isEmpty)
  }
  func testOriginalArchiveCostCanOnlyMoveToOneOwnerAndIsNeverAddedTwice()throws {
    let p=Samples.flightJacket(),run=CollectionRun(objectID:p.objects[0].id,quantity:2,includeAttachments:false);var plan=CollectionProductionPlan(name:"Cost ownership",runs:[run])
    let scope=try CollectionQuantities.scope(plan,project:p),target=scope.lines.first{$0.role=="component"}!.id
    var legacy=CollectionLine(id:"process/base",name:"Captured base",role:"unmapped",unit:.piece,quantity:"2",evidence:.declared,formula:"Original base",requiredCost:false);legacy.unitPrice="12.50";legacy.currency="USD";legacy.excludedReason="Unmapped"
    var r=CollectionLineRule(rowID:target);r.costSourceRowID=legacy.id;plan.rules=[r]
    let result=try CollectionEstimate.evaluate(plan,scope:scope,processRows:[legacy]);XCTAssertEqual(result.knownSubtotals,["USD":"25"]);XCTAssertEqual(result.completeTotal,"25")
    plan.rules[0].unitPrice="1";plan.rules[0].currency="USD";XCTAssertThrowsError(try CollectionEstimate.evaluate(plan,scope:scope,processRows:[legacy]))
  }
  func testLargePreflightIsBoundedWithoutUnitObjectExpansionAndRecordsMeasuredTiming()throws {
    var p=Project(name:"100 runs / 2000 rows");for i in 0..<100 {p.objects.append(try p.makeObject(recipeID:"textileLabel",name:"Source \(i)"))}
    var plan=CollectionProductionPlan(name:"Measured preflight",runs:p.objects.map{.init(objectID:$0.id,quantity:100000,includeAttachments:false)})
    for i in 0..<1800 {var e=CollectionExtraLine(name:"Declared trim \(i)",unit:.m);e.quantity="0.1";e.unitPrice="2.125";e.currency="USD";plan.extras.append(e)}
    var times:[Double]=[]
    for _ in 0..<12 {let start=Date();let report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p));times.append(Date().timeIntervalSince(start)*1000);XCTAssertEqual(report.rows.count,2000);XCTAssertEqual(report.occurrences.count,100);XCTAssertEqual(report.knownSubtotals,["USD":"382.5"])}
    times.sort();let median=(times[5]+times[6])/2,p95=times[11];print("COLLECTION45_PREFLIGHT_MS",median,p95)
    if let folder=ProcessInfo.processInfo.environment["FORM_COLLECTION_PROOF_DIR"] {let url=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:["runs":100,"rows":2000,"quantity_per_run":100000,"measured_iterations":12,"median_ms":median,"nearest_rank_p95_ms":p95,"scope":"Actual bounded core preflight; no unit object expansion, meshing or digitizing."],options:[.prettyPrinted,.sortedKeys]).write(to:url.appendingPathComponent("Performance.json"))}
    plan.extras.append(.init(name:"over limit"));XCTAssertThrowsError(try CollectionQuantities.scope(plan,project:p))
  }

  func testPurchasedAndMadeCostsRetainDormantDeclarationsWithoutDoubleCharging()throws {
    let p=Samples.flightJacket(),o=p.objects.first{$0.textile?.kind == .patch && $0.textile?.attachment==nil}!,run=CollectionRun(objectID:o.id,quantity:2,includeAttachments:false),id=run.id.uuidString+"/"+o.id.uuidString
    var plan=CollectionProductionPlan(name:"Purchase or make",runs:[run]),component=CollectionLineRule(rowID:id),material=CollectionLineRule(rowID:id+"/material")
    component.costBasis = .made;component.unitPrice="10";component.currency="USD";material.quantity="2";material.unit = .m;material.unitPrice="3";material.currency="USD";plan.rules=[component,material]
    var report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p));XCTAssertEqual(report.completeTotal,"6");XCTAssertNil(report.rows.first{$0.id==id}?.cost);XCTAssertEqual(plan.rules[0].unitPrice,"10")
    plan.rules[0].costBasis = .purchased;report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p));XCTAssertEqual(report.completeTotal,"20");XCTAssertNil(report.rows.first{$0.id==material.rowID}?.quantity);XCTAssertNil(report.rows.first{$0.id==material.rowID}?.cost)
    plan.rules[0].costBasis = .unresolved;report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p));XCTAssertNil(report.completeTotal);XCTAssertFalse(report.unknowns.isEmpty)
  }
  func testFoldedLayoutAndSharedPatternVariantsCountRollLengthAndStockOnceWithoutMeshing()throws {
    var p=Project(name:"Declared sewn variants"),stock=TextileDesign.materials.first{$0.id=="flight-nylon"}!;stock.fabric?.usableWidth=200;stock.fabric?.inventoryMeters=1;p.materials=[stock]
    var e=ArtworkElement(kind:"rectangle",x:0,y:0,width:20,height:30);e.sewingPiece = .init(name:"Actual panel");e.sewingPiece?.seamAllowance=0;e.sewingPiece?.cutQuantity=2;e.sewingPiece?.materialID=stock.id
    var owner=try p.makeObject(recipeID:"artboard");var art=Artwork(elements:[e]);var l=SewingCutLayout(materialID:stock.id,stockWidth:200);l.stock = .foldedPair;l.margin=0;l.spacing=0.1;l.costPerSquareMeter=10;l.costCurrency="USD";l.placements=[.init(elementID:e.id,copies:[1,2],x:0,y:0)];art.sewingLayout=l;owner.artwork=art
    let panels=[1,2].map{PatternPanelPlacement(panel:.init(elementID:e.id,copy:$0),pose:.init(),material:stock,densityGSM:180)}
    var first=try p.makeObject(recipeID:"patternAssembly",name:"Made variant A");first.patternAssembly = .init(sourceObjectID:owner.id,panels:panels,seamIDs:[])
    var second=first;second.id=UUID();second.name="Made variant B";p.objects=[owner,first,second]
    let a=CollectionRun(objectID:first.id,quantity:3,includeAttachments:false),b=CollectionRun(objectID:second.id,quantity:2,includeAttachments:false);var plan=CollectionProductionPlan(name:"Repeated full open width",runs:[a,b]);plan.layouts=[.init(runID:a.id,objectID:owner.id),.init(runID:b.id,objectID:owner.id)]
    let before=try JSONEncoder.form.encode(p),scope=try CollectionQuantities.scope(plan,project:p),report=try CollectionEstimate.evaluate(plan,scope:scope)
    XCTAssertEqual(report.occurrences.count,2);XCTAssertEqual(report.occurrences.reduce(0){$0+$1.quantity},5)
    XCTAssertEqual(try CollectionDecimal.sum(report.rows.filter{$0.role=="allocation"}.compactMap(\.quantity)),"0.15")
    XCTAssertEqual(report.knownSubtotals,["USD":"0.3"]);XCTAssertEqual(report.completeTotal,"0.3");XCTAssertEqual(report.stock.count,1);XCTAssertEqual(report.stock[0].knownDemand,"0.15");XCTAssertEqual(report.stock[0].status,"sufficient")
    XCTAssertEqual(try JSONEncoder.form.encode(p),before)
    plan.layouts.append(plan.layouts[0]);XCTAssertThrowsError(try CollectionQuantities.scope(plan,project:p))
  }

  func testExcludingARequiredStageDoesNotMakeAnIncompleteEstimateLookComplete()throws {
    let p=Samples.flightJacket(),o=p.objects.first{$0.textile?.kind == .patch && $0.textile?.attachment==nil}!
    let run=CollectionRun(objectID:o.id,quantity:2,includeAttachments:false),rowID=run.id.uuidString+"/"+o.id.uuidString
    var plan=CollectionProductionPlan(name:"Explicit scope",runs:[run]),component=CollectionLineRule(rowID:rowID),material=CollectionLineRule(rowID:rowID+"/material")
    component.costBasis = .made;material.quantity="2";material.unit = .m;material.unitPrice="3";material.currency="USD";plan.rules=[component,material]
    let scope=try CollectionQuantities.scope(plan,project:p)
    XCTAssertEqual(try CollectionEstimate.evaluate(plan,scope:scope).completeTotal,"6")
    plan.rules[1].excludedReason="Declared prototype review omits fabric purchasing."
    let report=try CollectionEstimate.evaluate(plan,scope:scope)
    XCTAssertNil(report.completeTotal);XCTAssertTrue(report.knownSubtotals.isEmpty)
    XCTAssertTrue(report.unknowns.contains{$0.contains("required costing stage explicitly excluded")})
    XCTAssertNil(report.rows.first{$0.id==material.rowID}?.cost);XCTAssertEqual(plan.rules[1].unitPrice,"3");XCTAssertEqual(plan.rules[1].quantity,"2")
  }
  func testEquivalentPersistedStockDatesDoNotCreateFalseAvailabilityConflicts()throws {
    let p=Samples.flightJacket(),run=CollectionRun(objectID:p.objects[0].id,includeAttachments:false)
    var plan=CollectionProductionPlan(name:"Portable thread",runs:[run]),a=CollectionExtraLine(name:"Front seam",unit:.m),b=CollectionExtraLine(name:"Back seam",unit:.m)
    a.quantity="0.1";b.quantity="0.2";plan.extras=[a,b]
    var thread=StudioThread(name:"Declared spool",color:"#334455");thread.updatedAt=Date(timeIntervalSince1970:1_700_000_000.123456);thread.availableMeters=1
    let decoded=try JSONDecoder.form.decode(StudioThread.self,from:JSONEncoder.form.encode(thread))
    var first=CollectionLineRule(rowID:"extra/"+a.id.uuidString),second=CollectionLineRule(rowID:"extra/"+b.id.uuidString)
    first.stock = .init(thread:thread);second.stock = .init(thread:decoded);plan.rules=[first,second]
    let report=try CollectionEstimate.evaluate(plan,scope:CollectionQuantities.scope(plan,project:p))
    XCTAssertEqual(report.stock.count,1);XCTAssertEqual(report.stock[0].knownDemand,"0.3");XCTAssertEqual(report.stock[0].status,"sufficient");XCTAssertEqual(report.stock[0].available,"1")
  }

}
