import AppKit
import FormCore

/// Frame controls use visual-point hit targets, independent of artwork zoom.
@MainActor enum CanvasArtboardResizing {
  static func supports(_ frame:CanvasFrame)->Bool {
    frame.projection == nil && !frame.legacyDieline && frame.sourceReview == nil && frame.editable
      && supports(frame.object)
  }
  static func supports(_ object:ProductObject)->Bool {
    object.recipeID == "artboard" && !object.isCanvasWorkspace && !object.locked
      && object.artworkSourceID == nil && object.componentDefinition != true && object.canvasSourceOnly != true
      && object.artworkParameterBindings?.isEmpty != false && object.artwork?.boundary == nil
      && object.artwork?.sewingLayout == nil && object.artwork?.elements.contains(where:{$0.sewingPiece != nil}) != true
  }
  static func points(_ rect:CGRect)->[CGPoint] {
    [.init(x:rect.minX,y:rect.minY),.init(x:rect.midX,y:rect.minY),.init(x:rect.maxX,y:rect.minY),
      .init(x:rect.maxX,y:rect.midY),.init(x:rect.maxX,y:rect.maxY),.init(x:rect.midX,y:rect.maxY),
      .init(x:rect.minX,y:rect.maxY),.init(x:rect.minX,y:rect.midY)]
  }
  static func handle(at point:CGPoint,rect:CGRect,scale:Double)->Int? {
    guard scale.isFinite,scale>0,rect.width>0,rect.height>0 else{return nil}
    let tolerance=5/scale,corners=[0,2,4,6],positions=points(rect)
    if let corner=corners.min(by:{hypot(point.x-positions[$0].x,point.y-positions[$0].y)<hypot(point.x-positions[$1].x,point.y-positions[$1].y)}),
      abs(point.x-positions[corner].x)<=7/scale,abs(point.y-positions[corner].y)<=7/scale {return corner}
    guard rect.insetBy(dx:-tolerance,dy:-tolerance).contains(point) else{return nil}
    let distances=[(1,abs(point.y-rect.minY)),(3,abs(point.x-rect.maxX)),
      (5,abs(point.y-rect.maxY)),(7,abs(point.x-rect.minX))]
    return distances.min(by:{$0.1<$1.1}).flatMap{$0.1<=tolerance ? $0.0:nil}
  }
  static func resized(_ rect:CGRect,handle:Int,delta:CGPoint,aspectLocked:Bool,fromCenter:Bool,
    minimum:Double=0.01,maximum:Double=10_000)->CGRect {
    guard (0..<8).contains(handle),rect.width>0,rect.height>0,delta.x.isFinite,delta.y.isFinite else{return rect}
    let left=[0,6,7].contains(handle),right=[2,3,4].contains(handle)
    let top=[0,1,2].contains(handle),bottom=[4,5,6].contains(handle),factor=fromCenter ? 2.0:1.0
    var width=rect.width+(left ? -delta.x:right ? delta.x:0)*factor
    var height=rect.height+(top ? -delta.y:bottom ? delta.y:0)*factor
    if aspectLocked {
      let sx=width/rect.width,sy=height/rect.height
      let proposed = !left && !right ? sy:!top && !bottom ? sx:abs(sx-1)>abs(sy-1) ? sx:sy
      let scale=max(max(minimum/rect.width,minimum/rect.height),min(min(maximum/rect.width,maximum/rect.height),proposed))
      width=rect.width*scale;height=rect.height*scale
    } else {width=max(minimum,min(maximum,width));height=max(minimum,min(maximum,height))}
    let anchor=fromCenter ? CGPoint(x:rect.midX,y:rect.midY):points(rect)[(handle+4)%8]
    let fraction=CGPoint(x:(anchor.x-rect.minX)/rect.width,y:(anchor.y-rect.minY)/rect.height)
    return CGRect(x:max(-100_000,min(100_000,anchor.x-width*fraction.x)),
      y:max(-100_000,min(100_000,anchor.y-height*fraction.y)),width:width,height:height)
  }
  static func draw(_ frame:CanvasFrame,context:CGContext,scale:Double,highlighted:Int?=nil) {
    guard supports(frame),scale>0 else{return}
    context.saveGState();defer{context.restoreGState()}
    // Canvas already draws the category-colored frame. Resize controls add
    // accent handles without repainting that persistent outline.
    context.setStrokeColor(Palette.accentNS.cgColor);context.setLineWidth(1/scale)
    for (index,point) in points(frame.rect).enumerated() {
      // At tiny scales show corners only, leaving a useful interior.
      if [1,5].contains(index),frame.rect.width*scale<28 {continue}
      if [3,7].contains(index),frame.rect.height*scale<28 {continue}
      let size=(highlighted==index ? 8.0:6.0)/scale
      let rect=CGRect(x:point.x-size/2,y:point.y-size/2,width:size,height:size)
      context.setFillColor((highlighted==index ? Palette.accentNS:NSColor.white).cgColor)
      context.fill(rect);context.stroke(rect)
    }
  }
}

extension ArtworkSession {
  /// Only the frame boundary changes. Left/top edges compensate root origins
  /// so existing content remains fixed on Canvas, without scaling any layer.
  func resizeCanvasArtboard(to rect:CGRect,from original:CGRect,artwork snapshot:Artwork,
    expectedFrameID:UUID,gestureToken:UUID) {
    guard activeFrameID==expectedFrameID,let store,
      store.engine.isInteracting(withGeneration:gestureToken) else{return}
    do {
      try store.engine.edit("Resized artboard",source:"Studio",coalescing:"artwork-\(expectedFrameID)") { project in
        guard let index=project.objects.firstIndex(where:{$0.id==expectedFrameID}),
          CanvasArtboardResizing.supports(project.objects[index]),
          let recipe=project.recipe(project.objects[index].recipeID),
          [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) else {
          throw FormError.invalid("Choose an unlocked independent rectangular artboard to resize.")
        }
        var parameters=project.objects[index].parameters
        parameters["width"]=rect.width;parameters["depth"]=rect.height
        try recipe.validate(parameters)
        var art=snapshot
        let dx=original.minX-rect.minX,dy=original.minY-rect.minY
        for i in art.elements.indices where art.elements[i].parentID == nil {
          ArtworkCommands.translate(&art.elements[i],dx:dx,dy:dy)
        }
        for i in art.guides?.indices ?? 0..<0 {art.guides![i].position += art.guides![i].axis == "x" ? dx:dy}
        art.canvasPosition = .init(rect.minX,rect.minY)
        try validateArtwork(art)
        project.objects[index].parameters=parameters;project.objects[index].artwork=art
      }
      store.changed()
    } catch {store.error=error.localizedDescription}
  }
}
