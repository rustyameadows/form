import FormCore
import Foundation
import XCTest
@testable import FormApp

final class StoryAnnotationHistoryTests:XCTestCase {
  private func range(_ value:StoryAnnotation?)->NSRange? {value.map{.init(location:$0.location,length:$0.length)}}
  private func move(_ history:StoryAnnotationHistory,from old:String,annotations:[StoryAnnotation]?,to new:String,undoing:Bool=false,redoing:Bool=false)->[StoryAnnotation]? {
    history.transition(from:old,annotations:annotations,to:new,
      proposed:StoryAnnotations.relocating(annotations,from:old,to:new),undoing:undoing,redoing:redoing)
  }

  func testDeletedWholeAnchorRestoresItsRangeOnIntermediateNativeUndoAndPointOnRedo()throws {
    let a="Lead target tail",b="NEW / "+a,c="NEW / Lead  tail"
    let note=StoryAnnotation(location:5,length:6,body:"Keep the original target")
    let history=StoryAnnotationHistory(text:a,annotations:[note])
    let afterInsert=move(history,from:a,annotations:[note],to:b)
    XCTAssertEqual(range(afterInsert?.first),.init(location:11,length:6))
    let afterDelete=move(history,from:b,annotations:afterInsert,to:c)
    XCTAssertEqual(range(afterDelete?.first),.init(location:11,length:0))
    let undone=move(history,from:c,annotations:afterDelete,to:b,undoing:true)
    XCTAssertEqual(undone,afterInsert,"Undo restores an intermediate anchor, not only the opening source")
    let redone=move(history,from:b,annotations:undone,to:c,redoing:true)
    XCTAssertEqual(redone,afterDelete)
    let undoDelete=move(history,from:c,annotations:redone,to:b,undoing:true)
    let undoInsert=move(history,from:b,annotations:undoDelete,to:a,undoing:true)
    XCTAssertEqual(undoInsert,[note])
  }

  func testExactRepeatedWordSplicesAndNearestDirectionalVersionsRemainDistinct()throws {
    let a="same same",note=StoryAnnotation(location:5,length:4,body:"Second original word")
    let history=StoryAnnotationHistory(text:a,annotations:[note]),b="same same same"
    let shifted=StoryAnnotations.replacing([note],in:a,range:.init(location:0,length:0),with:"same ")
    let one=history.transition(from:a,annotations:[note],to:b,proposed:shifted,undoing:false,redoing:false)
    XCTAssertEqual(range(one?.first),.init(location:10,length:4))
    // The same exact text version can recur with a different intended anchor.
    let returned=StoryAnnotations.replacing(one,in:b,range:.init(location:10,length:5),with:"")
    // Use a valid explicit last-word removal to return to the same source.
    let actual=StoryAnnotations.replacing(one,in:b,range:.init(location:9,length:5),with:"")
    XCTAssertEqual(returned,one,"Invalid range does not fabricate a source edit")
    let two=history.transition(from:b,annotations:one,to:a,proposed:actual,undoing:false,redoing:false)
    XCTAssertEqual(range(two?.first),.init(location:9,length:0))
    let c="same same!",three=move(history,from:a,annotations:two,to:c)
    let nearest=move(history,from:c,annotations:three,to:a,undoing:true)
    XCTAssertEqual(nearest,two,"Undo chooses the nearest earlier digest, retaining its distinct anchor")
    let previous=move(history,from:a,annotations:nearest,to:b,undoing:true)
    XCTAssertEqual(previous,one)
    XCTAssertEqual(move(history,from:b,annotations:previous,to:a,redoing:true),two)
  }

  func testMetadataBodyKindOrderNewIDsAndRemovalRemainCurrentDuringTextUndo()throws {
    let a="before target after",b="before  after"
    let first=StoryAnnotation(location:7,length:6,body:"Original body")
    let history=StoryAnnotationHistory(text:a,annotations:[first])
    let collapsed=move(history,from:a,annotations:[first],to:b)
    var edited=try XCTUnwrap(collapsed?.first);edited.body="Current body";edited.kind = .reference
    let added=StoryAnnotation(location:0,length:6,body:"Added after typing")
    history.recordCurrent(text:b,annotations:[added,edited])
    let undone=move(history,from:b,annotations:[added,edited],to:a,undoing:true)
    XCTAssertEqual(undone?.map(\.id),[added.id,first.id])
    XCTAssertEqual(undone?.last?.body,"Current body");XCTAssertEqual(undone?.last?.kind,.reference)
    XCTAssertEqual(range(undone?.last),.init(location:7,length:6))
    XCTAssertEqual(undone?.first,added,"An ID absent from the earlier snapshot retains its proposed anchor")
    history.recordCurrent(text:a,annotations:[added])
    let redone=move(history,from:a,annotations:[added],to:b,redoing:true)
    XCTAssertEqual(redone?.map(\.id),[added.id],"Text Redo must not revive a removed editorial record")
  }

  func testNewMetadataAtOpeningVersionSurvivesUndoOfLaterTyping() {
    let a="Anchor",b="Anchor more",history=StoryAnnotationHistory(text:a,annotations:nil)
    let note=StoryAnnotation(location:0,length:6,body:"Added before typing")
    history.recordCurrent(text:a,annotations:[note])
    let typed=move(history,from:a,annotations:[note],to:b)
    XCTAssertEqual(move(history,from:b,annotations:typed,to:a,undoing:true),[note])
  }

  func testNormalEditAfterUndoDiscardsTheOldFutureWithoutReusingItsRanges() {
    let a="abc def",b="abc  def",c="abc def!",note=StoryAnnotation(location:4,length:3,body:"def")
    let history=StoryAnnotationHistory(text:a,annotations:[note])
    let branchA=move(history,from:a,annotations:[note],to:b)
    let undone=move(history,from:b,annotations:branchA,to:a,undoing:true)
    let branchB=move(history,from:a,annotations:undone,to:c)
    let future=StoryAnnotations.relocating(branchB,from:c,to:b)
    let unexpectedRedo=history.transition(from:c,annotations:branchB,to:b,proposed:future,undoing:false,redoing:true)
    XCTAssertEqual(unexpectedRedo,future,"A fork has no right to restore a discarded future's anchor")
  }

  func testCanonicallyEquivalentSourceVersionsKeepDistinctUTF16UndoAndRedoAnchors() {
    let nfc="\u{00E9} Tail",nfd="e\u{0301} Tail"
    XCTAssertEqual(nfc,nfd)
    let accent=StoryAnnotation(location:0,length:1,body:"The original source accent")
    let tail=StoryAnnotation(location:2,length:4,body:"The original tail")
    let history=StoryAnnotationHistory(text:nfc,annotations:[accent,tail])
    let changed=move(history,from:nfc,annotations:[accent,tail],to:nfd)
    XCTAssertEqual(range(changed?.first),.init(location:0,length:0))
    XCTAssertEqual(range(changed?.last),.init(location:3,length:4))
    let undone=move(history,from:nfd,annotations:changed,to:nfc,undoing:true)
    XCTAssertEqual(undone,[accent,tail],"Native Undo restores the exact older code-unit anchor ranges")
    XCTAssertEqual(move(history,from:nfc,annotations:undone,to:nfd,redoing:true),changed)
  }

  func testEmojiSourceAndFormattingNoOpDoNotUseDisplayCaseOrStaleBaseline() {
    let a="straße 🙂 tail",b="STRASSE 🙂 tail",emoji=(a as NSString).range(of:"🙂")
    let note=StoryAnnotation(location:emoji.location,length:emoji.length,body:"Original UTF-16 emoji")
    let history=StoryAnnotationHistory(text:a,annotations:[note])
    XCTAssertEqual(history.transition(from:a,annotations:[note],to:a,proposed:[note],undoing:false,redoing:false),[note])
    let upper=move(history,from:a,annotations:[note],to:b)
    XCTAssertEqual(range(upper?.first),(b as NSString).range(of:"🙂"))
    XCTAssertEqual(move(history,from:b,annotations:upper,to:a,undoing:true),[note])
    // A replacement editor/source supplies its authoritative old text. Do not
    // let an earlier editor's digest history restore another source's ranges.
    let external=StoryAnnotation(id:note.id,location:0,length:1,body:"Reanchored externally")
    let proposed=StoryAnnotations.relocating([external],from:"external",to:b)
    XCTAssertEqual(history.transition(from:"external",annotations:[external],to:b,proposed:proposed,undoing:true,redoing:false),proposed)
  }
}
