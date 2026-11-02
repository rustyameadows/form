import AppKit
import FormCore

public enum PublicationPDFLayout:String,Codable,CaseIterable,Sendable {case pages,spreads,booklet}
public struct PublicationPDFPlacement:Codable,Equatable,Sendable {
  public var sourcePage:Int?
  public var objectID:UUID?
  public var xMM:Double
  public var widthMM:Double
  public var heightMM:Double
}
public struct PublicationPDFSide:Codable,Equatable,Sendable {
  public var index:Int
  public var sheet:Int?
  public var reverse:Bool
  public var widthMM:Double
  public var heightMM:Double
  public var bleedMM:Double
  public var placements:[PublicationPDFPlacement]
}
public struct PublicationPDFPlan:Codable,Equatable,Sendable {
  public var layout:PublicationPDFLayout
  public var sourcePageCount:Int
  public var addedBlankPages:Int
  public var sides:[PublicationPDFSide]
}

extension PublicationOutput {
  /// Reader spreads and two-up folded-sheet order are derived outputs. They
  /// never reorder saved pages, split stories or scale their physical artwork.
  public static func arrangement(_ project:Project,documentID:UUID,layout:PublicationPDFLayout,
    padToMultipleOfFour:Bool=false)throws->PublicationPDFPlan {
    try project.validatePublications()
    guard var document=project.publications?.first(where:{$0.id==documentID}),!document.pages.isEmpty else {
      throw FormError.invalid("Choose a publication with physical pages.")
    }
    let pages=try document.pages.map {page->(UUID,Double,Double,Double) in
      guard let object=project.objects.first(where:{$0.id==page.objectID}),let art=project.surfaceArtwork(object),
        object.artworkSize.x.isFinite,object.artworkSize.y.isFinite else{throw FormError.invalid("A publication page is missing its physical artwork.")}
      return(object.id,object.artworkSize.x,object.artworkSize.y,art.bleed)
    }
    var groups:[[Int?]]=[],padding=0
    switch layout {
    case .pages:groups=pages.indices.map{[$0]}
    case .spreads:
      if document.layout==nil {document.layout = .init(facingPages:true)}
      let indices=Dictionary(uniqueKeysWithValues:document.pages.enumerated().map{($0.element.id,$0.offset)})
      groups=document.spreads().map{$0.pages.map{indices[$0.id]}}
    case .booklet:
      guard pages.allSatisfy({abs($0.1-pages[0].1)<0.001 && abs($0.2-pages[0].2)<0.001}) else{
        throw FormError.invalid("Folded-sheet output requires matching page trim dimensions. Use reader pages or spreads for mixed sizes.")
      }
      let leading=document.layout?.firstPageSide == .verso ? 1:0
      padding=leading+(4-(pages.count+leading)%4)%4
      guard padding==0 || padToMultipleOfFour else{
        throw FormError.invalid("Folded-sheet output needs a multiple of four pages. Explicitly allow blank output pages or add source pages.")
      }
      let count=pages.count+padding
      func source(_ n:Int)->Int? {
        let index=n-leading
        return (0..<pages.count).contains(index) ? index:nil
      }
      for sheet in 0..<(count/4) {
        groups.append([source(count-1-sheet*2),source(sheet*2)])
        groups.append([source(sheet*2+1),source(count-2-sheet*2)])
      }
    }
    let sides=groups.enumerated().map {index,group->PublicationPDFSide in
      let dimensions=group.map{slot in slot.map{pages[$0]} ?? pages[0]}
      var x=0.0,placements=[PublicationPDFPlacement]()
      for (slot,size) in zip(group,dimensions) {
        placements.append(.init(sourcePage:slot.map{$0+1},objectID:slot.map{pages[$0].0},xMM:x,widthMM:size.1,heightMM:size.2));x+=size.1
      }
      return .init(index:index+1,sheet:layout == .booklet ? index/2+1:nil,reverse:layout == .booklet && index%2==1,
        widthMM:x,heightMM:dimensions.map{$0.2}.max() ?? 0,bleedMM:dimensions.map{$0.3}.min() ?? 0,placements:placements)
    }
    return .init(layout:layout,sourcePageCount:pages.count,addedBlankPages:padding,sides:sides)
  }

  public static func arrangedPreflight(_ project:Project,documentID:UUID,assets:URL?=nil,
    layout:PublicationPDFLayout = .pages,padToMultipleOfFour:Bool=false,
    inkOutput:InkOutputMode?=nil)->[String:Any] {
    var result=preflight(project,documentID:documentID,assets:assets,previewOnly:inkOutput == .preview)
    var issues=result["issues"] as? [[String:Any]] ?? []
    do {
      let plan=try arrangement(project,documentID:documentID,layout:layout,padToMultipleOfFour:padToMultipleOfFour)
      result["arrangement"]=try jsonObject(plan)
      if layout != .pages,inkOutput != .preview,
        project.publications?.first(where:{$0.id==documentID})?.pages.contains(where:{page in
          project.objects.first(where:{$0.id==page.objectID}).flatMap{project.surfaceArtwork($0)}?.requiresInkOutput==true
        })==true {
        throw FormError.invalid("This publication declares production inks. Choose an explicit appearance preview for arranged output.")
      }
      if layout != .pages,inkOutput == .composite || inkOutput == .plates {
        throw FormError.invalid("Production ink composites and plates retain source-page output. Choose appearance preview for arranged output.")
      }
      for side in plan.sides where side.placements.count>1 {
        let bleeds=side.placements.compactMap{placement in placement.objectID.flatMap{id in
          project.objects.first(where:{$0.id==id}).flatMap{project.surfaceArtwork($0)}?.bleed
        }}
        if let maximum=bleeds.max(),maximum-side.bleedMM>0.001 {
          issues.append(["severity":"warning","code":"shared_bleed","message":"Output side \(side.index) uses the common \(side.bleedMM) mm exterior bleed. Its source pages have different bleed allowances; larger allowances are clipped without changing trim or scale."])
        }
      }
    }catch{issues.append(["severity":"error","code":"page_arrangement","message":error.localizedDescription])}
    result["layout"]=layout.rawValue;result["issues"]=issues
    result["can_export"] = !issues.contains{$0["severity"] as? String=="error"}
    return result
  }

  public static func arrangedPDF(_ project:Project,documentID:UUID,assets:URL,dpi:Double=300,
    outlineText:Bool=false,allowOverset:Bool=false,inkOutput:InkOutputMode?=nil,
    layout:PublicationPDFLayout = .pages,padToMultipleOfFour:Bool=false)throws->Data {
    if layout == .pages {return try pdf(project,documentID:documentID,assets:assets,dpi:dpi,outlineText:outlineText,allowOverset:allowOverset,inkOutput:inkOutput)}
    guard inkOutput != .composite,inkOutput != .plates else{
      throw FormError.invalid("Production ink composites and plates retain source-page output. Export reader pages for those modes, or choose an explicit appearance preview for arranged output.")
    }
    let plan=try arrangement(project,documentID:documentID,layout:layout,padToMultipleOfFour:padToMultipleOfFour)
    guard let document=project.publications?.first(where:{$0.id==documentID}) else{throw FormError.missing("Publication not found.")}
    if inkOutput != .preview,document.pages.contains(where:{page in project.objects.first(where:{$0.id==page.objectID}).flatMap{project.surfaceArtwork($0)}?.requiresInkOutput==true}) {
      throw FormError.invalid("This publication declares production inks. Choose an explicit appearance preview for arranged output.")
    }
    let profile=inkOutput == .preview ? nil:try outputProfile(project,document:document)
    // Compose sRGB once, then apply the selected physical output profile once
    // after arranging. Named ink output remains on the original page path.
    let original=try pdf(project,documentID:documentID,assets:assets,dpi:dpi,outlineText:outlineText,allowOverset:allowOverset,inkOutput:.preview)
    guard let provider=CGDataProvider(data:original as CFData),let source=CGPDFDocument(provider) else{throw FormError.invalid("Could not read the composed publication pages.")}
    let data=NSMutableData();var media=CGRect(x:0,y:0,width:100,height:100)
    guard let consumer=CGDataConsumer(data:data),let context=CGContext(consumer:consumer,mediaBox:&media,
      [kCGPDFContextTitle:document.name,kCGPDFContextCreator:"LAB"] as CFDictionary) else{throw FormError.invalid("Could not create arranged publication output.")}
    func box(_ rect:CGRect)->Data {var rect=rect;return Data(bytes:&rect,count:MemoryLayout<CGRect>.size)}
    let factor=TypographyEngine.pointsPerMM
    for side in plan.sides {
      let media=CGRect(x:0,y:0,width:(side.widthMM+2*side.bleedMM)*factor,height:(side.heightMM+2*side.bleedMM)*factor)
      let trim=CGRect(x:side.bleedMM*factor,y:side.bleedMM*factor,width:side.widthMM*factor,height:side.heightMM*factor)
      context.beginPDFPage([kCGPDFContextMediaBox:box(media),kCGPDFContextCropBox:box(media),kCGPDFContextTrimBox:box(trim),kCGPDFContextBleedBox:box(media)] as CFDictionary)
      context.setFillColor(NSColor.white.cgColor);context.fill(media)
      for (i,placement) in side.placements.enumerated() {
        guard let number=placement.sourcePage,let page=source.page(at:number) else{continue}
        let sourceTrim=page.getBoxRect(.trimBox)
        let leftBleed=i==0 ? side.bleedMM:0,rightBleed=i==side.placements.count-1 ? side.bleedMM:0
        let clip=CGRect(x:(side.bleedMM+placement.xMM-leftBleed)*factor,y:0,
          width:(placement.widthMM+leftBleed+rightBleed)*factor,height:media.height)
        context.saveGState();context.clip(to:clip)
        context.translateBy(x:(side.bleedMM+placement.xMM)*factor-sourceTrim.minX,
          y:(side.bleedMM+side.heightMM-placement.heightMM)*factor-sourceTrim.minY)
        context.drawPDFPage(page);context.restoreGState()
      }
      context.endPDFPage()
    }
    context.closePDF()
    if let profile {return try ProfiledPDF.convert(data as Data,profile:ICCOutputProfile(reference:profile,assets:assets),title:document.name)}
    return data as Data
  }
}
