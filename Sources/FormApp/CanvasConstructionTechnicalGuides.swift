import AppKit
import FormCore

/// Complete accepted source values are the key; artwork, Canvas placement and
/// rigid presentation never enter this pure technical-geometry cache. One
/// preparation serves all of the owner's flat and upright face frames.
@MainActor enum CanvasConstructionTechnicalGuides {
  private struct Entry {let source:PaperConstruction,paths:[ConstructionArtworkTechnicalPath],cost:Int}
  private static var entries=[Entry](),bytes=0
  static func paths(_ source:PaperConstruction,net:PaperNet)throws->[ConstructionArtworkTechnicalPath] {
    var key=source;key.foldPercent=100;key.openingPercent=0;key.explosionPercent=nil
    key.annotations=[];key.artworkReviewRequired=false
    if let index=entries.firstIndex(where:{$0.source==key}) {
      let entry=entries.remove(at:index);entries.insert(entry,at:0);return entry.paths
    }
    let result=try ConstructionArtworkTechnicalGuides.resolve(key,net:net)
    let points=result.reduce(0){$0+$1.points.count+$1.holes.reduce(0){$0+$1.count}}
    let cost=(try JSONEncoder.form.encode(key)).count+points*32+result.reduce(0){$0+256+$1.id.utf8.count+$1.label.utf8.count}
    if cost<=8*1024*1024 {
      while bytes+cost>8*1024*1024 || entries.count>=16 {
        guard let last=entries.popLast() else{break};bytes-=last.cost
      }
      entries.insert(.init(source:key,paths:result,cost:cost),at:0);bytes+=cost
    }
    return result
  }
}

extension PaperOutput {
  /// Canvas interface only. No Artwork, SVG/PDF print fragment, source map or
  /// material texture receives these paths, even when structural guides show.
  static func drawConstructionReview(_ paths:[ConstructionArtworkTechnicalPath],context:CGContext,scale:Double) {
    let scale=max(0.001,scale)
    context.saveGState();defer{context.restoreGState()}
    func shape(_ points:[Point2],closed:Bool)->CGPath {
      let path=CGMutablePath();guard let first=points.first else{return path}
      path.move(to:.init(x:first.x,y:first.y))
      for point in points.dropFirst(){path.addLine(to:.init(x:point.x,y:point.y))}
      if closed{path.closeSubpath()};return path
    }
    for mark in paths {
      let color:NSColor,dash:[Double],fill:Double
      switch mark.role {
      case .adhesive,.glue:color=NSColor(hex:"#9D7333");dash=[4,2];fill=0.11
      case .glueExclusion:color=NSColor(hex:"#AC4E48");dash=[2,2];fill=0.08
      case .tapeContact:color=NSColor(hex:"#277D7B");dash=[3,2];fill=0.08
      case .stapleCrown:color=NSColor(hex:"#665184");dash=[];fill=0
      case .stapleEntry:color=NSColor(hex:"#665184");dash=[];fill=0
      case .stapleExit:color=NSColor(hex:"#665184");dash=[1,2];fill=0
      case .turnIn:color=NSColor(hex:"#89639B");dash=[5,2];fill=0
      case .seam:color=NSColor(hex:"#338476");dash=[2,2];fill=0
      case .score,.groove:color=NSColor(hex:"#AE6246");dash=[6,2,1,2];fill=0
      default:color=NSColor(hex:"#507C9A");dash=[4,2];fill=0
      }
      let path=CGMutablePath();path.addPath(shape(mark.points,closed:mark.closed))
      for hole in mark.holes {path.addPath(shape(hole,closed:mark.closed))}
      if mark.closed,fill>0 {
        context.addPath(path);context.setFillColor(color.withAlphaComponent(fill).cgColor);context.drawPath(using:.eoFill)
      }
      context.addPath(path);context.setLineWidth((mark.role == .stapleCrown ? 1.2:0.8)/scale)
      context.setStrokeColor(color.withAlphaComponent(0.9).cgColor);context.setLineDash(phase:0,lengths:dash.map{CGFloat($0/scale)});context.strokePath()
    }
  }
}
