import AppKit
import FormCore
import XCTest
@testable import FormApp

@MainActor final class CanvasPublicationPassthroughTests:XCTestCase {
  func testDenseNonPublicationFrameReadsReuseOriginalStorageAndPreserveProjectionIdentity()throws {
    var project=Project(name:"Independent physical source views")
    let source=try project.makeObject(recipeID:"artboard",name:"Canonical artwork",parameters:["width":300,"depth":200])
    project.objects=[source]
    let owner=UUID(),artwork=Artwork(background:"#FFFFFF")
    let frames=(0..<1189).map {index in
      CanvasFrame(object:source,surfaceObject:source,
        rect:.init(x:36,y:Double(index)*90,width:60,height:40),artwork:artwork,
        projection:.init(constructionID:owner,sourceID:source.id,panelID:"face-\(index)",inside:index%2==0,
          title:"Physical face \(index)",size:.init(60,40),sourceToLocal:.translation(-12,-9),boundary:[]))
    }
    let firstID=frames[0].id,lastID=frames[frames.count-1].id,before=try JSONEncoder.form.encode(project)
    let variants:[[PublicationDocument]?]=[nil,[],[
      .init(name:"Unpaired pages",pages:[.init(objectID:source.id)],layout:.init(facingPages:false))],[
      .init(name:"Empty facing document",pages:[],layout:.init(facingPages:true))]]
    for publications in variants {
      project.publications=publications
      for _ in 0..<32 {
        let sameStorage=frames.withUnsafeBufferPointer {original in
          let result=CanvasPublicationSpreads.applying(to:frames,project:project)
          XCTAssertEqual(result.count,1189)
          XCTAssertEqual(result[0].id,firstID);XCTAssertEqual(result[result.count-1].id,lastID)
          XCTAssertEqual(result[37].rect,frames[37].rect);XCTAssertEqual(result[37].projection,frames[37].projection)
          return result.withUnsafeBufferPointer{$0.baseAddress==original.baseAddress}
        }
        XCTAssertTrue(sameStorage,"An inapplicable publication lens must not copy the dense physical frame graph on each inspector read.")
      }
    }
    project.publications=nil
    XCTAssertEqual(try JSONEncoder.form.encode(project),before)
  }
}
