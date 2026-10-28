import Foundation

public enum ArtworkPageArea:String,Codable,CaseIterable,Sendable {case trim,bleed}

public struct ArtworkPageOptions:Equatable,Sendable {
  public var area:ArtworkPageArea
  public var cropMarks:Bool
  public var markGapMm:Double
  public var markLengthMm:Double
  public init(area:ArtworkPageArea = .bleed,cropMarks:Bool=false,markGapMm:Double=1,markLengthMm:Double=3) {
    self.area=area;self.cropMarks=cropMarks;self.markGapMm=markGapMm;self.markLengthMm=markLengthMm
  }
  public func validate()throws {
    guard markGapMm.isFinite,(0...25).contains(markGapMm),markLengthMm.isFinite,(0.1...25).contains(markLengthMm) else {
      throw FormError.invalid("Choose a finite 0–25 mm crop-mark gap and 0.1–25 mm length.")
    }
  }
}

public struct ArtworkCropMark:Equatable,Sendable {
  public var start:Point2,end:Point2
  public var strokeBoundsMm:Rect2 {
    let half=ArtworkPageGeometry.markStrokeMm/2
    if start.y==end.y {return .init(min(start.x,end.x),start.y-half,abs(end.x-start.x),2*half)}
    return .init(start.x-half,min(start.y,end.y),2*half,abs(end.y-start.y))
  }
}

/// All rectangles use the PDF's positive physical sheet coordinates. Source
/// artwork translates by drawingOriginMm and is never scaled by this geometry.
public struct ArtworkPageGeometry:Equatable,Sendable {
  public static let pointsPerMM=72.0/25.4
  public static let markStrokePoints=0.25
  public static let markStrokeMm=markStrokePoints/pointsPerMM
  public static let markTipPaddingMm=1.0
  public static let maximumMediaMm=5080.0
  public let options:ArtworkPageOptions
  public let declaredBleedMm:Double
  public let includedBleedMm:Double
  public let mediaMm:Rect2
  public let trimMm:Rect2
  public let bleedMm:Rect2
  public let safeMm:Rect2?
  public let marks:[ArtworkCropMark]
  public var drawingOriginMm:Point2 {.init(trimMm.x,trimMm.y)}

  public init(width:Double,height:Double,bleed:Double,safeInset:Double?,options:ArtworkPageOptions)throws {
    try options.validate()
    guard width.isFinite,height.isFinite,width>0,height>0,width<=10000,height<=10000,
      bleed.isFinite,(0...25).contains(bleed) else {
      throw FormError.invalid("A physical page needs positive finite frame dimensions and 0–25 mm bleed.")
    }
    if let safeInset {
      guard safeInset.isFinite,safeInset>=0,width-2*safeInset>0,height-2*safeInset>0 else {
        throw FormError.invalid("Safe inset must be finite, nonnegative and leave a nonempty frame interior.")
      }
    }
    let included=options.area == .bleed ? bleed:0
    let margin=included+(options.cropMarks ? options.markGapMm+options.markLengthMm+Self.markTipPaddingMm:0)
    let media=Rect2(0,0,width+2*margin,height+2*margin)
    guard media.width.isFinite,media.height.isFinite,media.width<=Self.maximumMediaMm,media.height<=Self.maximumMediaMm else {
      throw FormError.invalid("The complete physical PDF sheet exceeds 5080 mm without page-unit scaling. Reduce the page or use the existing tiled workflow.")
    }
    let trim=Rect2(margin,margin,width,height)
    let bleedBox=Rect2(margin-included,margin-included,width+2*included,height+2*included)
    var segments:[ArtworkCropMark]=[]
    if options.cropMarks {
      for sx in [-1.0,1.0] {for sy in [-1.0,1.0] {
        let x=sx<0 ? trim.x:trim.maxX,y=sy<0 ? trim.y:trim.maxY
        let near=included+options.markGapMm,far=near+options.markLengthMm
        segments.append(.init(start:.init(x+sx*near,y),end:.init(x+sx*far,y)))
        segments.append(.init(start:.init(x,y+sy*near),end:.init(x,y+sy*far)))
      }}
    }
    self.options=options;declaredBleedMm=bleed;includedBleedMm=included
    mediaMm=media;trimMm=trim;bleedMm=bleedBox;marks=segments
    safeMm=safeInset.flatMap{$0>0 ? Rect2(trim.x+$0,trim.y+$0,width-2*$0,height-2*$0):nil}
  }

  public var metadata:[String:Any] {
    func rect(_ r:Rect2)->[Double] {[r.x,r.y,r.width,r.height]}
    return ["units":"mm","area":options.area.rawValue,"declared_bleed_mm":declaredBleedMm,
      "included_bleed_mm":includedBleedMm,"media_box_mm":rect(mediaMm),"crop_box_mm":rect(mediaMm),
      "trim_box_mm":rect(trimMm),"bleed_box_mm":rect(bleedMm),"safe_guide_mm":safeMm.map(rect) as Any? ?? NSNull(),
      "source_origin_mm":[trimMm.x,trimMm.y],"source_scale":1,
      "crop_marks":marks.map{["start_mm":[$0.start.x,$0.start.y],"end_mm":[$0.end.x,$0.end.y],"stroke_bounds_mm":rect($0.strokeBoundsMm)]},
      "mark_stroke_points":Self.markStrokePoints,"mark_tip_padding_mm":options.cropMarks ? Self.markTipPaddingMm:0,
      "safe_guides_printed":false,"registration_marks":false,"hardware_contacted":false]
  }
}
