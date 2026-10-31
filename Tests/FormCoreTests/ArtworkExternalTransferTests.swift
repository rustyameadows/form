import Foundation
import XCTest
@testable import FormCore

final class ArtworkExternalTransferTests:XCTestCase {
  private func project(_ name:String="Destination")throws->(Project,UUID) {
    var project=Project(name:name);let owner=try project.ensureCanvasWorkspace();return(project,owner.id)
  }
  private func source()throws->(Artwork,[String:Data],UUID,UUID) {
    var a=ArtworkElement(kind:"group",x:0,y:0,width:40,height:30);a.name="A";a.contentSize = .init(40,30)
    var b=ArtworkElement(kind:"group",x:50,y:0,width:40,height:30);b.name="B";b.contentSize = .init(40,30)
    var one=ArtworkElement(kind:"text",x:2,y:3,width:30,height:15,text:"Editable A",fontSize:12);one.parentID=a.id
    one.sourceMetadata = .init(format:"figma",nodeID:"2:5",properties:Data("A settings".utf8))
    var two=ArtworkElement(kind:"text",x:2,y:3,width:30,height:15,text:"Unrelated B",fontSize:12);two.parentID=b.id
    let bytes=Data("Opaque original with A and unrelated B".utf8),name="source-"+ArtworkTransferBundle.digest(bytes)+".figma"
    var art=Artwork(background:"#FFFFFF",elements:[a,one,b,two]);art.backgroundOpacity=0
    art.imports=[.init(asset:name,name:"Native source",width:90,height:30,elementIDs:art.elements.map(\.id),format:"figma")]
    return(art,[name:bytes],a.id,b.id)
  }
  func testScopedOriginalTravelsOnlyWithItsEntireSourceClosure()throws {
    let(art,assets,a,b)=try source();var(p,id)=try project("Source");p.objects[0].artwork=art
    let partial=try ArtworkTransferGraph.capture(project:p,objectID:id,ids:[a],readAsset:{name,_ in
      XCTFail("A partial copy must not read the shared original containing B");return assets[name]!
    })
    XCTAssertEqual(Set(partial.metadata.artwork.elements.map(\.name).compactMap{$0}),["A"])
    XCTAssertEqual(partial.metadata.artwork.elements.compactMap(\.sourceMetadata).first?.properties,Data("A settings".utf8))
    XCTAssertTrue(partial.metadata.artwork.imports?.isEmpty ?? true);XCTAssertTrue(partial.blobs.isEmpty)
    XCTAssertFalse(partial.metadata.artwork.elements.contains{$0.id==b})
    let complete=try ArtworkTransferGraph.capture(project:p,objectID:id,ids:[a,b],readAsset:{name,_ in assets[name]!})
    XCTAssertEqual(complete.blobs,assets)
    let wire=try complete.encoded(),decoded=try ArtworkTransferBundle.decode(wire)
    XCTAssertEqual(decoded.metadata.artwork,art)
    let(destination,target)=try project(),plan=try ArtworkTransferGraph.plan(decoded,into:destination,objectID:target)
    let pasted=try XCTUnwrap(plan.project.canvasWorkspace?.artwork)
    XCTAssertEqual(Set(try XCTUnwrap(pasted.imports?.first?.elementIDs)),Set(pasted.elements.map(\.id)))
    XCTAssertTrue(Set(art.elements.map(\.id)).isDisjoint(with:Set(pasted.elements.map(\.id))))
    XCTAssertEqual(pasted.elements.compactMap(\.sourceMetadata),art.elements.compactMap(\.sourceMetadata))
    XCTAssertEqual(plan.assetWrites.values.first,assets.values.first)
  }
  func testTwoSeparateImportsPermitCopyingOneWholeGroup()throws {
    let(art,_,a,_)=try source();var p=try project("Source").0;let owner=p.objects[0].id
    var single=art;let chosen=art.descendants(of:[a]);single.elements.removeAll{!chosen.contains($0.id)}
    let bytes=Data("Independent original containing only A".utf8),name="source-"+ArtworkTransferBundle.digest(bytes)+".figma"
    let assets=[name:bytes]
    single.imports=[.init(asset:name,name:"A source",width:40,height:30,elementIDs:single.elements.map(\.id),format:"figma")]
    let other=ArtworkElement(kind:"rectangle",x:100,y:100,width:30,height:20)
    single.elements.append(other);p.objects[0].artwork=single
    let copied=try ArtworkTransferGraph.capture(project:p,objectID:owner,ids:[a],readAsset:{name,_ in assets[name]!})
    XCTAssertEqual(copied.metadata.artwork.elements.count,2)
    XCTAssertEqual(copied.metadata.artwork.imports?.count,1)
    XCTAssertFalse(copied.metadata.artwork.elements.contains{$0.id==other.id})
  }
  func testPartialDescendantCopyDoesNotCarryAncestorOverrideText()throws {
    let(art,_,a,_)=try source();var p=try project("Source").0
    var value=art;value.imports=nil
    let index=try XCTUnwrap(value.elements.firstIndex{$0.id==a})
    value.elements[index].sourceMetadata = .init(format:"figma",nodeID:"1:2",properties:Data("Overrides including unrelated sibling text".utf8))
    var sibling=ArtworkElement(kind:"text",x:1,y:1,text:"Private sibling");sibling.parentID=a;value.elements.append(sibling)
    p.objects[0].artwork=value
    let leaf=try XCTUnwrap(value.elements.first{$0.parentID==a && $0.id != sibling.id})
    let copied=try ArtworkTransferGraph.capture(project:p,objectID:p.objects[0].id,ids:[leaf.id],readAsset:{_,_ in XCTFail("No opaque bytes expected");return Data()})
    XCTAssertNil(copied.metadata.artwork.elements.first{$0.id==a}?.sourceMetadata)
    XCTAssertEqual(copied.metadata.artwork.elements.first{$0.id==leaf.id}?.sourceMetadata,leaf.sourceMetadata)
    XCTAssertFalse(copied.metadata.artwork.elements.contains{$0.id==sibling.id})
  }
  func testExternalGraphPreservesDestinationDefaultsAndRoundTripsNativeSettings()throws {
    var(p,id)=try project();p.objects[0].artwork!.language="fr";p.objects[0].artwork!.unit = .inches
    p.objects[0].artwork!.elements=[.init(kind:"ellipse",x:2,y:3,width:5,height:5)]
    var layer=ArtworkElement(kind:"text",x:10,y:20,width:80,height:30,text:"Edited later",fontSize:12)
    layer.sourceMetadata = .init(format:"figma",nodeID:"3:7",properties:Data("Original text style".utf8),version:"101")
    let bundle=try ArtworkTransferBundle.external(artwork:.init(elements:[layer]),selection:[layer.id],assets:[:],application:"Figma")
    XCTAssertEqual(bundle.metadata.sourceApplication,"Figma")
    let plan=try ArtworkTransferGraph.plan(bundle,into:p,objectID:id,offset:.init(0,0)),result=try XCTUnwrap(plan.project.canvasWorkspace?.artwork)
    XCTAssertEqual(result.language,"fr");XCTAssertEqual(result.unit,.inches)
    XCTAssertEqual(result.elements.last?.sourceMetadata,layer.sourceMetadata)
    XCTAssertEqual(plan.project.minimumSchemaVersion,58)
    let bytes=try JSONEncoder.form.encode(plan.project),restored=try JSONDecoder.form.decode(Project.self,from:bytes)
    XCTAssertEqual(restored.objects,plan.project.objects)
  }
  func testNativeProvenanceCannotMasqueradeAsRenderableImageAndMetadataIsBounded()throws {
    let(art,assets,a,_)=try source()
    var invalid=art;invalid.elements[0].kind="image";invalid.elements[0].asset=assets.keys.first
    XCTAssertThrowsError(try ArtworkTransferBundle.external(artwork:invalid,selection:[a],assets:assets,application:"Figma"))
    var layer=ArtworkElement(kind:"rectangle",x:0,y:0)
    layer.sourceMetadata = .init(format:"figma",nodeID:"1:1",properties:Data(repeating:0,count:256*1024+1))
    XCTAssertThrowsError(try validateArtwork(.init(elements:[layer])))
  }
  func testDenseExternalGraphAndNativeRecopyUseTheSameBudget()throws {
    var group=ArtworkElement(kind:"group",x:0,y:0,width:500,height:500);group.contentSize = .init(500,500)
    let children=(0..<2499).map{i -> ArtworkElement in
      var value=ArtworkElement(kind:"rectangle",x:Double(i%50)*5,y:Double(i/50)*5,width:4,height:4)
      value.parentID=group.id;value.name="Layer \(i)";return value
    }
    let bundle=try ArtworkTransferBundle.external(artwork:.init(elements:[group]+children),selection:[group.id],assets:[:],application:"Figma")
    let decoded=try ArtworkTransferBundle.decode(bundle.encoded()),(p,id)=try project()
    let plan=try ArtworkTransferGraph.plan(decoded,into:p,objectID:id)
    let copied=try ArtworkTransferGraph.capture(project:plan.project,objectID:id,ids:plan.selection,readAsset:{_,_ in XCTFail("No assets expected");return Data()})
    XCTAssertEqual(copied.metadata.artwork.elements.count,2500)
    XCTAssertEqual(Set(copied.metadata.artwork.elements.compactMap(\.name)),Set(children.compactMap(\.name)))
  }
}
