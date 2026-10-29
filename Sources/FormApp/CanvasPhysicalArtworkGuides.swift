import AppKit
import FormCore

/// Derived guides share the current physical source and never create an
/// editable layer, mesh, saved asset, or additional Undo owner.
@MainActor final class CanvasPhysicalArtworkGuideCache {
  private struct Entry {var revision:String;var report:PhysicalArtworkIntentReport;var cost:Int}
  private var entries:[UUID:Entry]=[:]
  private var order:[UUID]=[]
  private var bytes=0
  private(set) var builds=0
  var count:Int {entries.count}
  func clear(){entries=[:];order=[];bytes=0}
  func retain(_ ids:Set<UUID>) {
    for id in Array(entries.keys) where !ids.contains(id) {remove(id)}
  }
  private func remove(_ id:UUID) {
    if let old=entries.removeValue(forKey:id){bytes-=old.cost}
    order.removeAll{$0==id}
  }
  func report(for object:ProductObject,in project:Project) -> PhysicalArtworkIntentReport? {
    guard object.physicalArtworkIntents?.isEmpty == false else{remove(object.id);return nil}
    guard let revision=try? project.physicalArtworkIntentRevision(for:object) else{remove(object.id);return nil}
    if let entry=entries[object.id],entry.revision==revision{return entry.report}
    remove(object.id);builds+=1
    guard let report=try? project.physicalArtworkIntentReport(for:object) else{return nil}
    let points=report.guides.reduce(0){sum,guide in
      sum+(guide.trim+guide.bleed+guide.safe).reduce(0){$0+$1.count}
    }
    let cost=points*32+report.issues.count*1024+report.guides.count*1024
    if cost<=16*1024*1024 {
      while bytes+cost>16*1024*1024 || entries.count>=32 {
        guard let first=order.first else{break};remove(first)
      }
      entries[object.id] = .init(revision:revision,report:report,cost:cost)
      bytes+=cost;order.append(object.id)
    }
    return report
  }
}

extension CanvasFrame {
  // An ordinary sewing frame edits its canonical source even when selection
  // previews an assembly. Projected paper/CAD frames own their surface intent.
  var physicalGuideObject:ProductObject {projection == nil ? object:surfaceObject}
  var physicalGuideIntents:[PhysicalArtworkIntent] {
    let projection=self.projection
    let side:PhysicalArtworkSurfaceIdentity.Side=projection?.inside == true ? .inside:.outside
    return (physicalGuideObject.physicalArtworkIntents ?? []).filter {intent in
      guard intent.surface.side==side else{return false}
      if let projection {
        if PaperConstruction.isPaper(surfaceObject) {
          return projection.isProof || intent.surface.kind == .net
            || (intent.surface.kind == .panel && intent.surface.surfaceID==projection.panelID)
        }
        return intent.surface.kind == .cadSurface && intent.surface.surfaceID==projection.panelID
      }
      return intent.surface.kind == .sewingPiece
    }
  }
  func physicalGuideBounds(report:PhysicalArtworkIntentReport,scale:Double) -> CGRect {
    let matching=physicalGuideIntents,ids=Set(matching.map(\.id))
    let transform=projection?.sourceToLocal ?? .init()
    var local=CGRect.null
    for guide in report.guides where ids.contains(guide.intent.id) {
      for ring in guide.trim+guide.bleed+guide.safe {for point in ring {
        let p=transform.apply(point)
        local=local.union(.init(x:p.x,y:p.y,width:0,height:0))
      }}
    }
    if projection?.isProof == false {
      let bleed=matching.map(\.bleedMM).max() ?? 0
      local=local.intersection(CGRect(origin:.zero,size:rect.size).insetBy(dx:-bleed-2/scale,dy:-bleed-2/scale))
    }
    if isWorkspace {return local.isNull ? .null:local.offsetBy(dx:rect.minX,dy:rect.minY)}
    return local.isNull ? rect:rect.union(local.offsetBy(dx:rect.minX,dy:rect.minY))
  }
}

extension VectorCanvasView {
  func drawPhysicalArtworkGuides(_ frame:CanvasFrame,report:PhysicalArtworkIntentReport,
    context:CGContext,scale:Double,active:Bool) {
    let projection=frame.projection,matching=frame.physicalGuideIntents
    let ids=Set(matching.map(\.id))
    guard !ids.isEmpty else{return}
    let guides=report.guides.filter{ids.contains($0.intent.id)}
    context.saveGState()
    if projection?.isProof == false {
      let bleed=guides.map{$0.intent.bleedMM}.max() ?? 0
      context.clip(to:CGRect(origin:.zero,size:frame.rect.size).insetBy(dx:-bleed-2/scale,dy:-bleed-2/scale))
    }
    context.setLineWidth(1/scale)
    context.setLineDash(phase:0,lengths:[5/scale,3/scale])
    for guide in guides {
      let local=guide.transformed(by:projection?.sourceToLocal ?? .init())
      if guide.intent.bleedMM>0 {
        context.setStrokeColor(NSColor(hex:"#A43C9D").cgColor)
        for ring in local.bleed {context.addPath(PaperOutput.path(ring));context.strokePath()}
      }
      if guide.intent.safeInsetMM>0 {
        context.setStrokeColor(NSColor(hex:"#267D75").cgColor)
        for ring in local.safe {context.addPath(PaperOutput.path(ring));context.strokePath()}
      }
    }
    context.restoreGState()
    if active,report.issues.contains(where:{!ids.isDisjoint(with:$0.surfaceIDs)}) {
      let origin=frame.isWorkspace
        ? CGPoint(x:visibleCanvasRect.minX-frame.rect.minX+12/scale,y:visibleCanvasRect.minY-frame.rect.minY+12/scale)
        : CGPoint(x:0,y:frame.rect.height+3/scale)
      ("Artwork guides need review" as NSString).draw(at:origin,
        withAttributes:[.font:NSFont.systemFont(ofSize:10/scale),.foregroundColor:NSColor(hex:"#9D5A10")])
    }
  }
}
