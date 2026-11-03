import Foundation

/// Nonprinting editorial metadata on the original, global UTF-16 story source.
/// References are literal user-authored text; they never fetch or execute URLs.
public struct StoryAnnotation:Codable,Equatable,Identifiable,Sendable {
  public enum Kind:String,Codable,CaseIterable,Sendable {case note,reference}
  public var id:UUID
  public var location:Int,length:Int
  public var kind:Kind
  public var body:String
  public init(id:UUID=UUID(),location:Int,length:Int,kind:Kind = .note,body:String) {
    self.id=id;self.location=location;self.length=length;self.kind=kind;self.body=body
  }
}

/// Optional precise edit information for source publishers. It is not persisted.
public struct StoryTextEdit:Equatable,Sendable {
  public var range:NSRange
  public var text:String
  public init(range:NSRange,text:String){self.range=range;self.text=text}
}

public enum StoryAnnotations {
  public static let maximumCount=256,maximumBodyBytes=4096,maximumTotalBodyBytes=65536
  public static func validRange(_ range:NSRange,in text:String)->Bool {
    let original=text as NSString
    guard range.location>=0,range.length>=0,range.location<=original.length,
      range.length<=original.length-range.location else{return false}
    func boundary(_ offset:Int)->Bool {
      offset==0 || offset==original.length || !(0xD800...0xDBFF).contains(original.character(at:offset-1)) || !(0xDC00...0xDFFF).contains(original.character(at:offset))
    }
    return boundary(range.location) && boundary(range.location+range.length)
  }
  public static func validate(_ annotations:[StoryAnnotation]?,in text:String)throws {
    let values=annotations ?? []
    guard values.count<=maximumCount,Set(values.map(\.id)).count==values.count,
      values.allSatisfy({!$0.body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.body.utf8.count<=maximumBodyBytes && validRange(.init(location:$0.location,length:$0.length),in:text)}),
      values.reduce(0,{$0+$1.body.utf8.count})<=maximumTotalBodyBytes else {
      throw FormError.invalid("Story notes/references need unique IDs, surrogate-safe source UTF-16 ranges, and nonempty bodies up to 4096 UTF-8 bytes; at most 256 entries and 65536 body bytes per story.")
    }
  }

  /// Before/at-start insertions follow the original selected text; insertions
  /// inside expand the anchor, and end insertions stay outside. Point anchors
  /// follow insertion at their position. Fully replaced text leaves a point at
  /// the replacement start, retaining the editorial record rather than deleting it.
  public static func replacing(_ annotations:[StoryAnnotation]?,in original:String,range:NSRange,with replacement:String)->[StoryAnnotation]? {
    guard let annotations,!annotations.isEmpty,validRange(range,in:original) else{return annotations}
    if (original as NSString).substring(with:range).utf16.elementsEqual(replacement.utf16) {return annotations}
    let start=range.location,end=start+range.length,added=replacement.utf16.count,delta=added-range.length
    return annotations.map { annotation in
      guard validRange(.init(location:annotation.location,length:annotation.length),in:original) else{return annotation}
      var result=annotation
      let a=annotation.location,b=a+annotation.length
      if range.length==0 {
        if start<=a {result.location+=added}
        else if start<b {result.length+=added}
      } else if b<=start {
        // A point at the edit start follows the replaced source, just like an
        // insertion there. A nonempty range ending there remains before it.
        if annotation.length==0,a==start {result.location=start+added}
      } else if a>=end {result.location+=delta}
      else if a>=start,b<=end {result.location=start;result.length=0}
      else {
        let lower=a<start ? a:start
        let upper=b>end ? b+delta:start+added
        result.location=lower;result.length=max(0,upper-lower)
      }
      return result
    }
  }

  /// A full-source replacement has no edit-operation history. Treat the common
  /// unchanged prefix/suffix as stable and its middle as one replacement. Callers
  /// with an exact splice should supply StoryTextEdit, particularly for repeated
  /// identical words where a whole-string comparison cannot recover intent.
  public static func relocating(_ annotations:[StoryAnnotation]?,from original:String,to replacement:String)->[StoryAnnotation]? {
    guard annotations?.isEmpty==false,!original.utf16.elementsEqual(replacement.utf16) else{return annotations}
    let old=Array(original.utf16),new=Array(replacement.utf16)
    var prefix=0
    while prefix<min(old.count,new.count),old[prefix]==new[prefix] {prefix+=1}
    func boundary(_ values:[UInt16],_ index:Int)->Bool {
      index==0 || index==values.count || !(0xD800...0xDBFF).contains(values[index-1]) || !(0xDC00...0xDFFF).contains(values[index])
    }
    while prefix>0,(!boundary(old,prefix) || !boundary(new,prefix)) {prefix-=1}
    var suffix=0
    while suffix<min(old.count-prefix,new.count-prefix),old[old.count-1-suffix]==new[new.count-1-suffix] {suffix+=1}
    while suffix>0,(!boundary(old,old.count-suffix) || !boundary(new,new.count-suffix)) {suffix-=1}
    let text=String(decoding:new[prefix..<(new.count-suffix)],as:UTF16.self)
    return replacing(annotations,in:original,range:.init(location:prefix,length:old.count-prefix-suffix),with:text)
  }
}

extension PublicationCommands {
  @discardableResult public static func upsertAnnotation(in project:inout Project,storyID:UUID,annotation:StoryAnnotation)throws->UUID {
    var candidate=project
    guard let index=candidate.textStories?.firstIndex(where:{$0.id==storyID}) else{throw FormError.missing("Text story not found.")}
    try ensureEditable(candidate.textStories![index],in:candidate)
    var values=candidate.textStories![index].annotations ?? []
    if let position=values.firstIndex(where:{$0.id==annotation.id}) {values[position]=annotation}else{values.append(annotation)}
    try StoryAnnotations.validate(values,in:candidate.textStories![index].text)
    candidate.textStories![index].annotations=values
    try candidate.validatePublications();project=candidate;return annotation.id
  }
  public static func removeAnnotation(in project:inout Project,storyID:UUID,annotationID:UUID)throws {
    var candidate=project
    guard let index=candidate.textStories?.firstIndex(where:{$0.id==storyID}),candidate.textStories![index].annotations?.contains(where:{$0.id==annotationID})==true else{throw FormError.missing("Story annotation not found.")}
    try ensureEditable(candidate.textStories![index],in:candidate)
    candidate.textStories![index].annotations?.removeAll{$0.id==annotationID}
    if candidate.textStories![index].annotations?.isEmpty==true {candidate.textStories![index].annotations=nil}
    try candidate.validatePublications();project=candidate
  }
}
