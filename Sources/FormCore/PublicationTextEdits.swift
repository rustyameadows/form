import Foundation
import CryptoKit

/// Edits original UTF-16 source. Display case conversion and shaped glyphs remain
/// derived; unaffected formatting and paragraph/glyph identities retain ownership.
public enum PublicationTextEdits {
  public static func replacing(_ source:ArtworkElement,range:NSRange,with text:String,derivedParagraphNamespace:UUID?=nil)throws->ArtworkElement {
    let original=source.text as NSString
    guard range.location>=0,range.length>=0,range.location<=original.length,range.length<=original.length-range.location else{throw FormError.invalid("Use a bounded source UTF-16 range.")}
    let end=range.location+range.length
    func boundary(_ offset:Int)->Bool {offset==0 || offset==original.length || !(0xD800...0xDBFF).contains(original.character(at:offset-1)) || !(0xDC00...0xDFFF).contains(original.character(at:offset))}
    guard source.kind=="text",source.storyFrame==nil,range.location>=0,range.length>=0,range.location<=original.length,
      range.length<=original.length-range.location,boundary(range.location),boundary(end) else{throw FormError.invalid("Use a source UTF-16 range without splitting a surrogate pair.")}
    var result=source;result.text=original.replacingCharacters(in:range,with:text)
    guard result.text.count<=100000 else{throw FormError.invalid("A story supports up to 100,000 original characters.")}
    let added=text.utf16.count,delta=added-range.length
    func shifted(_ type:Typography)->Typography {
      var copy=type;copy.pairKerning=Dictionary(uniqueKeysWithValues:type.pairKerning.compactMap{key,value in
        key<range.location ? (key,value):(key>=end ? (key+delta,value):nil)
      });return copy
    }
    result.typography=result.typography.map(shifted)
    if source.textRuns != nil {
      let spans=PublicationCommands.sourceSpans(source)
      var runs:[TextSpan]=[]
      for span in spans {
        let spanEnd=span.location+span.length
        if span.location<range.location {
          var prefix=span;prefix.length=min(spanEnd,range.location)-span.location;prefix.typography=shifted(prefix.typography)
          if prefix.length>0 {runs.append(prefix)}
        }
        if spanEnd>end {
          var suffix=span;let begin=max(span.location,end);suffix.location=begin+delta;suffix.length=spanEnd-begin;suffix.typography=shifted(suffix.typography)
          if suffix.length>0 {runs.append(suffix)}
        }
      }
      if added>0,var inserted=spans.first(where:{$0.location<=range.location && $0.location+$0.length>range.location}) ?? spans.last {
        inserted.location=range.location;inserted.length=added;inserted.typography=shifted(inserted.typography);runs.append(inserted)
      }
      runs.sort{$0.location<$1.location}
      var merged:[TextSpan]=[]
      for run in runs {
        if var previous=merged.last,previous.location+previous.length==run.location {
          var a=previous,b=run;a.location=0;a.length=0;b.location=0;b.length=0
          if a==b {previous.length+=run.length;merged[merged.count-1]=previous;continue}
        }
        merged.append(run)
      }
      result.textRuns=merged.isEmpty ? nil:merged
    }
    result.glyphOverrides=source.glyphOverrides?.compactMap{choice in
      var copy=choice
      if range.length==0,choice.location<range.location,choice.location+choice.length>range.location {return nil}
      if range.length>0,choice.location<end,choice.location+choice.length>range.location {return nil}
      if choice.location>=end {copy.location+=delta};return copy
    }
    if result.glyphOverrides?.isEmpty==true {result.glyphOverrides=nil}
    let oldParagraphs=ParagraphLists.ranges(in:source.text),newParagraphs=ParagraphLists.ranges(in:result.text)
    var items:[ParagraphListItem]=[],occupied=Set<Int>()
    func paragraphStart(_ position:Int)->Int {newParagraphs.last(where:{$0.location<=position})?.location ?? 0}
    for item in source.listItems ?? [] {
      guard let paragraph=oldParagraphs.first(where:{$0.location==item.location}) else{continue}
      if paragraph.location>=range.location,NSMaxRange(paragraph)<=end,range.length>0,added==0 {continue}
      if item.location>range.location,item.location<end {continue}
      var copy=item;copy.location=paragraphStart(item.location>=end ? item.location+delta:item.location);copy.resolvedNumber=nil
      if occupied.insert(copy.location).inserted {items.append(copy)}
    }
    if added>0,let inherited=(source.listItems ?? []).last(where:{$0.location<=range.location}) {
      let previous=oldParagraphs.last(where:{$0.location<=range.location})
      if previous?.location==inherited.location {
        for paragraph in newParagraphs where paragraph.location>=range.location && paragraph.location<=range.location+added && !occupied.contains(paragraph.location) {
          var copy=inherited
          if let namespace=derivedParagraphNamespace {
            var bytes=Array(SHA256.hash(data:Data("\(namespace):\(inherited.id):\(paragraph.location)".utf8)).prefix(16))
            bytes[6]=(bytes[6]&0x0f)|0x50;bytes[8]=(bytes[8]&0x3f)|0x80
            copy.id=UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
          }else{copy.id=UUID()}
          copy.location=paragraph.location;copy.restart=nil;copy.resolvedNumber=nil
          occupied.insert(copy.location);items.append(copy)
        }
      }
    }
    result.listItems=items.isEmpty ? nil:items.sorted{$0.location<$1.location}
    // A caller may be editing text inside a real group or a read-only runtime
    // master. Validate this node's source metadata without inventing/flattening
    // its surrounding hierarchy; the owning artwork validates those references.
    var isolated=result;isolated.parentID=nil;isolated.clipID=nil
    try validateArtwork(Artwork(elements:[isolated]),maxTextCharacters:100000)
    return result
  }
}
