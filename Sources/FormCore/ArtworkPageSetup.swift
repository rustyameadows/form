import Foundation
import CoreFoundation

public enum ArtworkPageSetup {
  public static func number(_ raw:Any,_ label:String)throws->Double {
    guard let n=raw as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else{throw FormError.invalid("Use a finite numeric \(label) in millimeters.")}
    return n.doubleValue
  }
  public static func options(_ raw:Any)throws->ArtworkPageOptions {
    guard let value=raw as? [String:Any],Set(value.keys).isSubset(of:["area","crop_marks","mark_gap_mm","mark_length_mm"]),let name=value["area"] as? String,let area=ArtworkPageArea(rawValue:name) else{throw FormError.invalid("page_output needs area trim or bleed and only supported crop-mark options.")}
    var options=ArtworkPageOptions(area:area)
    if let raw=value["crop_marks"] {
      guard let n=raw as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{throw FormError.invalid("crop_marks must be Boolean.")};options.cropMarks=n.boolValue
    }
    if let raw=value["mark_gap_mm"] {options.markGapMm=try number(raw,"crop-mark gap")}
    if let raw=value["mark_length_mm"] {options.markLengthMm=try number(raw,"crop-mark length")}
    try options.validate();return options
  }
  public static func source(_ project:Project,objectID:UUID,requireUnlocked:Bool=true)throws->ProductObject {
    guard let object=project.objects.first(where:{$0.id==objectID}),object.recipeID=="artboard",!object.isCanvasWorkspace,object.artworkSourceID==nil,project.artworkOwner(object).id==object.id,let art=object.artwork,art.boundary==nil,(!requireUnlocked || !object.locked),object.artworkSize.x.isFinite,object.artworkSize.y.isFinite,object.artworkSize.x>0,object.artworkSize.y>0 else{throw FormError.invalid("Choose an unlocked independent rectangular artwork frame for page setup and physical page output.")}
    return object
  }
  public static func apply(in project:inout Project,objectID:UUID,arguments:[String:Any])throws {
    guard Set(arguments.keys).isSubset(of:["object_id","command","bleed","safe_inset"]),arguments["bleed"] != nil || arguments["safe_inset"] != nil else{throw FormError.invalid("Page setup needs bleed and/or safe_inset, without element selections or unrelated options.")}
    let object=try source(project,objectID:objectID);var art=object.artwork!
    if let raw=arguments["bleed"] {art.bleed=try number(raw,"bleed")}
    if let raw=arguments["safe_inset"] {art.safeInset=raw is NSNull ? nil:try number(raw,"safe inset")}
    try validateArtwork(art)
    if let safe=art.safeInset {try validateSafe(safe,width:object.artworkSize.x,height:object.artworkSize.y)}
    var candidate=project;try candidate.setArtwork(art,for:object.id);try candidate.validatePageSetups();project=candidate
  }
  public static func validateSafe(_ safe:Double,width:Double,height:Double)throws {
    guard safe.isFinite,safe>=0,width.isFinite,height.isFinite,width>2*safe,height>2*safe else{throw FormError.invalid("Safe inset must be finite, nonnegative and leave a nonempty frame interior. Resize the inset explicitly before making the frame smaller.")}
  }
  /// Conservative whole-story counts precede PDF/signature construction. A
  /// repeated story frame counts its complete shared source again, not only ink.
  public static func sourceWorkload(_ artwork:Artwork)throws->[String:Int] {
    guard artwork.elements.count<=5000 else{throw FormError.invalid("Physical page output supports at most 5000 resolved elements.")}
    var text=0,nodes=0,runs=0;var images=Set<String>()
    func checked(_ value:Int,_ total:inout Int,_ maximum:Int,_ label:String)throws {
      guard value<=maximum-total else{throw FormError.invalid("Physical page output exceeds its aggregate \(label) source work limit.")};total+=value
    }
    for e in artwork.elements {
      let source=e.storyFrame?.resolved?.story.sourceElement ?? e
      try checked(source.text.utf16.count,&text,1_000_000,"one-million UTF-16")
      try checked(source.textRuns?.count ?? 0,&runs,16384,"16,384 rich-span")
      for contour in e.path?.contours ?? [] {try checked(contour.nodes.count,&nodes,250000,"250,000 vector-node")}
      if e.kind=="image",let name=e.asset {images.insert(name);guard images.count<=128 else{throw FormError.invalid("Physical page output supports at most 128 declared image assets.")}}
    }
    return ["resolved_elements":artwork.elements.count,"source_utf16":text,"rich_spans":runs,"vector_nodes":nodes,"declared_images":images.count]
  }
  public static func containsOnlyPageSetupChanges(_ previous:Project,_ current:Project)->Bool {
    var a=previous,b=current;var changed=false
    guard a.id==b.id,a.objects.map(\.id)==b.objects.map(\.id) else{return false}
    for i in a.objects.indices {
      if a.objects[i].artwork?.bleed != b.objects[i].artwork?.bleed || a.objects[i].artwork?.safeInset != b.objects[i].artwork?.safeInset {changed=true}
      a.objects[i].artwork?.bleed=0;b.objects[i].artwork?.bleed=0;a.objects[i].artwork?.safeInset=nil;b.objects[i].artwork?.safeInset=nil
    }
    a.history=[];b.history=[];a.updatedAt=Date(timeIntervalSince1970:0);b.updatedAt=a.updatedAt;a.schemaVersion=1;b.schemaVersion=1
    return changed && a==b
  }
}
extension Project {
  public func validatePageSetups()throws {
    for object in objects {
      if let safe=object.artwork?.safeInset {
        guard !object.isCanvasWorkspace else{throw FormError.invalid("A safe inset requires a finite physical frame.")}
        try ArtworkPageSetup.validateSafe(safe,width:object.artworkSize.x,height:object.artworkSize.y)
      }
    }
  }
}
