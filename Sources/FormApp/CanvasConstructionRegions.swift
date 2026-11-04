import AppKit
import FormCore

extension VectorCanvasView {
  /// Interface-only; these regions never enter the artwork/PDF/texture paths.
  func drawConstructionRegions(_ frame:CanvasFrame,context:CGContext,scale:Double) {
    guard frame.projection==nil,frame.object.artwork?.showGuides != false,
      let project=session?.store?.project,
      let regions=try? project.resolvedArtworkRegions(for:frame.object),!regions.isEmpty else{return}
    context.saveGState();defer{context.restoreGState()}
    context.setStrokeColor(NSColor(hex:"#526FA2").withAlphaComponent(0.7).cgColor)
    context.setLineWidth(0.75/scale);context.setLineDash(phase:0,lengths:[4/scale,3/scale])
    for region in regions {
      let rect=CGRect(x:region.origin.x,y:region.origin.y,width:region.size.x,height:region.size.y)
      context.stroke(rect)
      // Narrow spine/joint guides still need readable labels without spilling
      // into their neighbors. Use the long axis and clip each label to its guide.
      context.saveGState();context.clip(to:rect)
      let vertical=rect.width*scale<96 && rect.height*scale>=96
      let length=(vertical ? rect.height:rect.width)-8/scale
      if length>12/scale {
        if vertical {
          context.translateBy(x:rect.maxX-4/scale,y:rect.minY+4/scale)
          context.rotate(by:.pi/2)
        }else{context.translateBy(x:rect.minX+4/scale,y:rect.minY+4/scale)}
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        (region.name as NSString).draw(in:CGRect(x:0,y:0,width:length,height:12/scale),withAttributes:[
          .font:NSFont.systemFont(ofSize:9/scale,weight:.medium),.foregroundColor:NSColor(hex:"#526FA2"),.paragraphStyle:paragraph])
      }
      context.restoreGState()
    }
  }
}
