import CryptoKit
import FormCore
import Foundation

/// Session-local anchor snapshots parallel native text Undo. No source strings,
/// annotation bodies, kinds or deleted annotation records are retained here.
/// Its lifetime must match the editor/native Undo manager, without a separate
/// checkpoint cap that could truncate a grouped native Undo's destination.
final class StoryAnnotationHistory {
  // Unicode normalization can preserve Swift String equality while changing
  // every later UTF-16 offset. Match actual source bytes, not canonical equality.
  private struct Identity:Equatable {
    let digest:Data
    let utf16Length:Int
    init(_ text:String){digest=Data(SHA256.hash(data:Data(text.utf8)));utf16Length=text.utf16.count}
  }
  private struct Snapshot {
    let identity:Identity
    var ranges:[UUID:NSRange]
  }
  private var snapshots:[Snapshot]
  private var current=0

  init(text:String,annotations:[StoryAnnotation]?) {
    snapshots=[.init(identity:Identity(text),ranges:Self.ranges(annotations,in:text))]
  }
  private static func ranges(_ annotations:[StoryAnnotation]?,in text:String)->[UUID:NSRange] {
    var result:[UUID:NSRange]=[:]
    for annotation in annotations ?? [] {
      let range=NSRange(location:annotation.location,length:annotation.length)
      if StoryAnnotations.validRange(range,in:text) {result[annotation.id]=range}
    }
    return result
  }
  private func snapshot(text:String,annotations:[StoryAnnotation]?)->Snapshot {
    let ranges=Self.ranges(annotations,in:text)
    // Unchanged anchors share their value buffer instead of allocating another
    // dictionary for each source keystroke that does not move an editorial mark.
    return .init(identity:Identity(text),ranges:ranges==snapshots[current].ranges ? snapshots[current].ranges:ranges)
  }

  /// Metadata CRUD updates this source version's anchor map without changing
  /// text Undo order. A different source means the caller replaced/reset its
  /// editing baseline; obsolete text history must not restore unrelated ranges.
  func recordCurrent(text:String,annotations:[StoryAnnotation]?) {
    let next=snapshot(text:text,annotations:annotations)
    if next.identity==snapshots[current].identity {snapshots[current].ranges=next.ranges}
    else {snapshots=[next];current=0}
  }

  func transition(from oldText:String,annotations old:[StoryAnnotation]?,to newText:String,proposed:[StoryAnnotation]?,undoing:Bool,redoing:Bool)->[StoryAnnotation]? {
    recordCurrent(text:oldText,annotations:old)
    let nextIdentity=Identity(newText)
    guard nextIdentity != snapshots[current].identity else {
      recordCurrent(text:newText,annotations:proposed)
      return proposed
    }
    let destination:Int?
    if undoing && !redoing {
      destination=snapshots[..<current].lastIndex(where:{$0.identity==nextIdentity})
    }else if redoing && !undoing {
      destination=snapshots[(current+1)...].firstIndex(where:{$0.identity==nextIdentity})
    }else{destination=nil}
    if let destination {
      let ranges=snapshots[destination].ranges
      // Restore only ranges belonging to IDs that still exist. Current metadata
      // is authoritative: retain its order/body/kind and newly added records.
      let restored=proposed.map { values in values.map { annotation in
        guard let range=ranges[annotation.id],StoryAnnotations.validRange(range,in:newText) else{return annotation}
        var value=annotation;value.location=range.location;value.length=range.length;return value
      }}
      current=destination
      snapshots[current].ranges=Self.ranges(restored,in:newText)
      return restored
    }
    let next=snapshot(text:newText,annotations:proposed)
    if undoing || redoing {
      // An unmatched native destination is an external baseline, not permission
      // to match a similarly worded range in another source/version later.
      snapshots=[next];current=0
    }else {
      snapshots.removeSubrange((current+1)...)
      snapshots.append(next);current+=1
    }
    return proposed
  }
}
