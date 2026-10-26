import AppKit
import CoreText
import XCTest
@testable import FormCore
@testable import FormGraphics

@MainActor final class OpticalTypographyTests:XCTestCase {
  private let face=".AppleSystemUIFont"
  private func style(_ value:OpticalSizing?=nil)->Typography {var t=Typography();t.fontName=face;t.opticalSizing=value;t.kerningMode="metrics";return t}
  private func advance(_ font:NSFont)->Double {var c:UniChar=65,g:CGGlyph=0;CTFontGetGlyphsForCharacters(font as CTFont,&c,&g,1);return CTFontGetAdvancesForGlyphs(font as CTFont,.horizontal,&g,nil,1)}
  private func coordinate(_ font:NSFont)->Double? {(CTFontCopyVariation(font as CTFont) as? [NSNumber:NSNumber])?[NSNumber(value:OpticalSizing.axisID)]?.doubleValue}
  private func element(_ type:Typography)->ArtworkElement {var e=ArtworkElement(kind:"text",x:5,y:5,width:160,height:35,text:"Optical office",color:"#203A4A",fontSize:36);e.typography=type;return e}
  private func fixture()throws->(Project,UUID,UUID) {var p=Project(name:"Optical typography");var o=try p.makeObject(recipeID:"artboard",parameters:["width":180,"depth":100]);let e=element(style());var a=Artwork(elements:[e]);a.backgroundOpacity=0;o.artwork=a;p.objects=[o];return(p,o.id,e.id)}
  func testNilUsesExactLegacyFontDescriptorAndDoesNotChangeSchema()throws {
    var t=style();t.variations=[OpticalSizing.axisID:72];t.features=[1:3]
    let base=NSFont(name:face,size:36)!,legacy=NSFont(descriptor:base.fontDescriptor.addingAttributes([.variation:[NSNumber(value:OpticalSizing.axisID):NSNumber(value:72)],.featureSettings:[[NSFontDescriptor.FeatureKey.typeIdentifier:1,.selectorIdentifier:3]]]),size:36)!
    let actual=TypographyEngine.font(t,size:36);XCTAssertEqual(actual.fontName,legacy.fontName);XCTAssertEqual(advance(actual),advance(legacy));XCTAssertEqual(coordinate(actual),coordinate(legacy))
    let data=try JSONEncoder.form.encode(t);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("opticalSizing"));XCTAssertEqual(try JSONDecoder.form.decode(Typography.self,from:data),t)
    var(p,_,_)=try fixture();p.objects[0].artwork!.elements[0].typography=t;XCTAssertLessThan(p.minimumSchemaVersion,42)
  }
  func testAutomaticUsesNominalSourcePointSizeAcrossDrawingUnitsAndZoom()throws {
    let t=style(.init(.automatic)),point=TypographyEngine.font(t,size:36),f=TypographyEngine.pointsPerMM
    let attrs=TypographyEngine.attributes(t,size:36,color:"#203A4A",millimeters:true),mm=try XCTUnwrap(attrs[.font] as? NSFont)
    XCTAssertEqual(coordinate(point),36);XCTAssertEqual(coordinate(mm),36)
    XCTAssertEqual(advance(mm)*f,advance(point),accuracy:1e-10)
    for zoom in [0.1,0.5,1.0,2,10] {let displayedAdvance=advance(mm)*zoom;XCTAssertEqual(displayedAdvance/zoom*f,advance(point),accuracy:1e-10)}
    let small=TypographyEngine.font(t,size:8);XCTAssertEqual(coordinate(small),OpticalTypography.axis(face)!.minimum)
    let large=TypographyEngine.font(t,size:144);XCTAssertEqual(coordinate(large),OpticalTypography.axis(face)!.maximum)
  }
  func testExplicitAndDisabledAreRealMetricsAndRetainDormantSourceAxes()throws {
    var t=style(.init(.explicit,points:72));t.variations=[OpticalSizing.axisID:17,2003265652:400];let before=t
    let explicit=TypographyEngine.font(t,size:36);XCTAssertEqual(coordinate(explicit),72)
    t.opticalSizing = .init(.automatic);let auto=TypographyEngine.font(t,size:36)
    t.opticalSizing = .init(.none);let none=TypographyEngine.font(t,size:36)
    XCTAssertNotEqual(advance(explicit),advance(auto));XCTAssertNotEqual(advance(none),advance(auto));XCTAssertNil(coordinate(none))
    XCTAssertEqual(t.variations,before.variations)
    t.setOpticalSizing(nil);XCTAssertNil(t.opticalSizing);XCTAssertNil(t.variations[OpticalSizing.axisID]);XCTAssertEqual(t.variations[2003265652],400)
  }
  func testNamedInstanceActuallyAppliesOpticalAttributeWithMatchingDerivedAxis()throws {
    var t=style(.init(.explicit,points:19.5));t.fontName="SFCompact-Black"
    let axis=try XCTUnwrap(OpticalTypography.axis(t.fontName)),explicit=TypographyEngine.font(t,size:36)
    XCTAssertEqual(coordinate(explicit),19.5);XCTAssertEqual(axis.minimum,19);XCTAssertEqual(axis.maximum,20)
    t.opticalSizing = .init(.none);let none=TypographyEngine.font(t,size:36)
    XCTAssertNil(coordinate(none));XCTAssertNotEqual(advance(none),advance(explicit))
    t.opticalSizing = .init(.automatic);let point=TypographyEngine.font(t,size:36),mm=TypographyEngine.font(t,size:36/TypographyEngine.pointsPerMM,opticalPointSize:36)
    XCTAssertEqual(coordinate(point),20);XCTAssertEqual(advance(mm)*TypographyEngine.pointsPerMM,advance(point),accuracy:1e-10)
  }
  func testInvalidEditedValuesRejectAndStoredIncompatibleValuesRemainReportable()throws {
    for n in [Double.nan,Double.infinity,-1,0] {XCTAssertThrowsError(try OpticalSizing(.explicit,points:n).validate())}
    XCTAssertThrowsError(try OpticalSizing(.automatic,points:12).validate())
    for n in [1.0,100] {XCTAssertThrowsError(try OpticalTypography.validateEdit(.init(.explicit,points:n),fontName:face))}
    var t=style(.init(.explicit,points:72));t.variations=[OpticalSizing.axisID:19,123:2];let before=t
    t.fontName="Georgia";XCTAssertNotNil(OpticalTypography.warning(t));XCTAssertEqual(t.opticalSizing,before.opticalSizing);XCTAssertEqual(t.variations,before.variations)
    t=style(.init(.explicit,points:100));XCTAssertNotNil(OpticalTypography.warning(t));XCTAssertEqual(coordinate(TypographyEngine.font(t,size:36)),96);XCTAssertEqual(t.opticalSizing?.points,100)
  }
  func testCharacterCommandPreservesWordsOutsideSpansAxesAndSurrogateBoundaries()throws {
    var e=element(style());e.text="A😀B office";e.typography!.variations=[OpticalSizing.axisID:72];let before=e
    var art=Artwork(elements:[e]);try OpticalCommands.assign(&art,ids:[e.id],arguments:["optical_sizing":["mode":"automatic"],"location":1,"length":2])
    let runs=try XCTUnwrap(art.elements[0].textRuns);XCTAssertEqual(runs.map(\.length),[1,2,8]);XCTAssertNil(runs[0].typography.opticalSizing);XCTAssertEqual(runs[1].typography.opticalSizing,.init(.automatic));XCTAssertEqual(runs[1].typography.variations,before.typography!.variations);XCTAssertEqual(art.elements[0].text,before.text)
    let saved=art
    for args:[String:Any] in [["optical_sizing":["mode":"none"],"location":1,"length":1],["optical_sizing":["mode":"explicit","points":true]],["optical_sizing":["mode":"automatic","points":24]],[:]] {XCTAssertThrowsError(try OpticalCommands.assign(&art,ids:[e.id],arguments:args));XCTAssertEqual(art,saved)}
  }
  func testOpticalStyleInheritanceLocalOverrideResetAndSchemaReopen()throws {
    var(p,id,eid)=try fixture();let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let styleID=try TextStyleCommands.save(in:&p,name:"Optical text",typography:style(.init(.automatic)),fontSize:36)
    try TextStyleCommands.apply(in:&p,objectID:id,ids:[eid],styleID:styleID)
    var a=p.objects[0].artwork!;a.elements[0].typography!.opticalSizing = .init(.explicit,points:72);try p.setArtwork(a,for:id)
    XCTAssertTrue(p.objects[0].artwork!.elements[0].textStyle!.overrides.contains("opticalSizing"))
    try TextStyleCommands.save(in:&p,id:styleID,name:"Optical text",typography:style(.init(.none)),fontSize:36)
    XCTAssertEqual(p.objects[0].artwork!.elements[0].typography!.opticalSizing,.init(.explicit,points:72))
    try TextStyleCommands.apply(in:&p,objectID:id,ids:[eid],mode:"reset");XCTAssertEqual(p.objects[0].artwork!.elements[0].typography!.opticalSizing,.init(.none))
    XCTAssertEqual(p.minimumSchemaVersion,42);let repository=try ProjectRepository(root:root);try repository.save(p);let restored=try repository.load(p.id)
    XCTAssertEqual(restored.schemaVersion,42);XCTAssertEqual(restored.objects,p.objects);XCTAssertEqual(restored.textStyles,p.textStyles)
    p.objects=[];XCTAssertEqual(p.minimumSchemaVersion,42,"An unused reusable style still needs its optical policy preserved")
  }
  func testNativeMetadataRoundtripDoesNotBakeResolvedAxisIntoSourceAndSVGUsesOutlines()throws {
    var t=style(.init(.automatic));t.variations=[OpticalSizing.axisID:72];t.caseTreatment="uppercase";t.featureSelections=[1:[2]]
    let e=element(t);var source=TypographyEngine.sourceAttributed(e)
    for _ in 0..<4 {
      let spans=TypographyEngine.spans(from:source,fallback:t);XCTAssertEqual(spans.first?.typography,t)
      var copy=e;copy.textRuns=spans;source=TypographyEngine.sourceAttributed(copy)
    }
    let a=Artwork(elements:[e]),before=try JSONEncoder.form.encode(a),svg=try SVGRenderer.document(a,width:180,height:100,assets:FileManager.default.temporaryDirectory,outlineText:false)
    XCTAssertFalse(svg.contains("<text"));XCTAssertTrue(svg.contains("<path"));XCTAssertEqual(try JSONEncoder.form.encode(a),before)
    var ordinary=e;ordinary.typography=style();let live=try SVGRenderer.document(Artwork(elements:[ordinary]),width:180,height:100,assets:FileManager.default.temporaryDirectory,outlineText:false);XCTAssertTrue(live.contains("<text"))
  }
  func testSharedGlobalStoryRetainsGlyphListsCaseStylesAndFrameSourcesAcrossOpticalCommand()throws {
    var(p,id,eid)=try fixture();var source=p.objects[0].artwork!.elements[0];source.text="Q office\nAssembly note";source.typography!.caseTreatment="uppercase";source.typography!.variations=[OpticalSizing.axisID:72]
    let font=NSFont(name:face,size:36)!,gid=Int(CTFontGetGlyphWithName(font as CTFont,"Q" as CFString)),glyph=try GlyphCatalog.glyph(fontName:face,id:gid)
    source.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:glyph)];source.listItems=[.init(location:0,marker:.decimal,restart:1)]
    p.objects[0].artwork!.elements=[source]
    var second=try p.makeObject(recipeID:"artboard",parameters:["width":180,"depth":100]);var capacity=source;capacity.id=UUID();capacity.text="";capacity.glyphOverrides=nil;capacity.listItems=nil;second.artwork = .init(elements:[capacity]);p.objects.append(second)
    let storyID=try PublicationCommands.createStory(in:&p,frames:[.init(objectID:id,elementID:eid),.init(objectID:second.id,elementID:capacity.id)])
    let frames=p.objects,before=p.textStories![0]
    XCTAssertTrue(try PublicationCommands.editText(in:&p,objectID:id,ids:[eid],command:"optical",arguments:["optical_sizing":["mode":"explicit","points":72.0],"location":0,"length":1],prepareOptical:{art,ids,args in try OpticalTypography.validateCommand(art,ids:ids,arguments:args)}))
    XCTAssertEqual(p.objects,frames);XCTAssertEqual(p.textStories![0].id,storyID);XCTAssertEqual(p.textStories![0].text,before.text)
    XCTAssertEqual(p.textStories![0].glyphOverrides,before.glyphOverrides);XCTAssertEqual(p.textStories![0].listItems,before.listItems)
    XCTAssertEqual(p.textStories![0].textRuns?.first?.typography.opticalSizing,.init(.explicit,points:72))
    try GlyphEngine.validateOutput(p.textStories![0].sourceElement,outlines:true)
    XCTAssertEqual(p.minimumSchemaVersion,42)
    let replacement=try FontUsage.replacing(in:p,from:face,to:"Georgia")
    XCTAssertEqual(replacement.textStories![0].glyphOverrides,before.glyphOverrides)
    XCTAssertEqual(replacement.textStories![0].textRuns?.first?.typography.opticalSizing,.init(.explicit,points:72))
    XCTAssertEqual(replacement.textStories![0].textRuns?.first?.typography.variations,[OpticalSizing.axisID:72])
    XCTAssertFalse(FontLibraryCatalog.settingsWarnings(replacement,face:"Georgia").isEmpty)
    XCTAssertThrowsError(try GlyphEngine.validateOutput(replacement.textStories![0].sourceElement,outlines:true),"Exact glyph identity must remain unresolved rather than be reinterpreted after an intentional font replacement")
  }

  func testOpticalAlternateDiscoveryKeepsOriginalGlyphIdentityAndNominalPreviewContext()throws {
    for points in [12.0,72] {
      let type=style(.init(.automatic)),options=try GlyphCatalog.alternates(fontName:face,text:"Q",range:.init(location:0,length:1),typography:type,pointSize:points)
      let current=try XCTUnwrap(options.first{$0.current});var e=element(type);e.text="Q";e.fontSize=points
      let original=current.glyph;e.glyphOverrides=[.init(location:0,sourceText:"Q",glyph:original)]
      try GlyphEngine.validateOutput(e,outlines:true)
      XCTAssertEqual(e.glyphOverrides?.first?.glyph,original)
      let font=TypographyEngine.font(type,size:48,opticalPointSize:points),glyph=try GlyphCatalog.resolve(original,font:font,sourceFace:face)
      var id=glyph
      let advance=CTFontGetAdvancesForGlyphs(font as CTFont,.horizontal,&id,nil,1)/48
      XCTAssertEqual(current.advance,advance,accuracy:1e-10)
    }
  }

  func testIntentionalStyleResetClearsNewPolicyAndLegacyOpticalAxisTogether()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
    let engine=OperationEngine(repository:try ProjectRepository(root:root));var(p,_,_)=try fixture();var type=style(.init(.automatic));type.variations=[OpticalSizing.axisID:72,2003265652:400]
    let id=try TextStyleCommands.save(in:&p,name:"Optical reset",typography:type,fontSize:36);engine.project=p
    _ = try engine.call("form_text_style",arguments:["command":"update","style_id":id.uuidString,"typography":["opticalSizing":NSNull()]])
    let reset=engine.project!.textStyles![0].typography;XCTAssertNil(reset.opticalSizing);XCTAssertNil(reset.variations[OpticalSizing.axisID]);XCTAssertEqual(reset.variations[2003265652],400)
    engine.undo();XCTAssertEqual(engine.project,p)
  }

}
