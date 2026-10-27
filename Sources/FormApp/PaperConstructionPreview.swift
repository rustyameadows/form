import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct PaperConstructionPreview:View {
  let object:ProductObject
  let representation:PaperRepresentation
  var body:some View {
    if representation == .panels {
      GeometryReader {proxy in
        let columns=max(1,Int(proxy.size.width/210))
        let count=(try? PaperConstruction.definition(for:object).net().panels.count) ?? 1
        let rows=Int(ceil(Double(count)/Double(columns)))
        ScrollView(.vertical) {
          PaperConstructionPreviewSurface(object:object,representation:representation)
            .frame(width:proxy.size.width,height:max(proxy.size.height,Double(rows)*160+55))
        }.clipped()
      }
    } else {PaperConstructionPreviewSurface(object:object,representation:representation)}
  }
}

private struct PaperConstructionPreviewSurface:NSViewRepresentable {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  let representation:PaperRepresentation
  func makeNSView(context:Context)->PaperConstructionPreviewView {
    let view=PaperConstructionPreviewView(frame:.zero)
    // Keep the tall native drawing surface inside SwiftUI's scrolling viewport.
    view.clipsToBounds=true
    view.wantsLayer=true
    view.layer?.masksToBounds=true
    return view
  }
  func updateNSView(_ view:PaperConstructionPreviewView,context:Context) {
    view.store=store;view.object=object;view.representation=representation;view.synchronize()
  }
}

@MainActor final class PaperConstructionPreviewView:NSView {
  weak var store:StudioStore?
  var object:ProductObject?
  var representation:PaperRepresentation = .panels
  private var cachedArtwork:Artwork?
  private var cachedSize:Point2?
  private var cachedAssets:URL?
  private var image:NSImage?
  private var hitPanels:[(CGRect,String)]=[]
  private var hitPanelPaths:[(CGPath,String)]=[]
  private var net:PaperNet?
  private var problem:String?
  override var isFlipped:Bool{true}
  override var acceptsFirstResponder:Bool{true}
  override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
  func synchronize() {
    do {
      guard let object,let store,let project=store.project else{return}
      let definition=try PaperConstruction.definition(for:object);net=try definition.net()
      let artwork=store.paperShowingArtwork ? project.paperArtwork(for:object,inside:store.paperInside):nil
      let assets=store.repository.url(for:project.id).appendingPathComponent("Assets")
      if cachedArtwork != artwork || cachedSize != net?.size || cachedAssets != assets {
        cachedArtwork=artwork;cachedSize=net?.size;cachedAssets=assets
        if let artwork,let size=net?.size {image=ArtworkRenderer.image(artwork,width:size.x,height:size.y,assets:assets,pixelsPerMM:min(4,1800/max(size.x,size.y)))}else{image=nil}
      }
      problem=nil
    } catch {net=nil;image=nil;cachedArtwork=nil;cachedSize=nil;cachedAssets=nil;problem=error.localizedDescription}
    needsDisplay=true
  }
  private func text(_ value:String,at point:CGPoint,size:Double=11,color:NSColor=NSColor(hex:"#7C8078")) {
    (value as NSString).draw(at:point,withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color])
  }
  private func drawImage(net:PaperNet,context:CGContext) {
    context.saveGState();context.addPath(PaperOutput.clipPath(net));context.clip()
    let stock=object.map { $0.color ?? store?.project?.material($0.materialID).color ?? "#F7F5EF" } ?? "#F7F5EF"
    context.setFillColor(NSColor(hex:stock).cgColor);context.fill(.init(x:0,y:0,width:net.size.x,height:net.size.y))
    image?.draw(in:.init(x:0,y:0,width:net.size.x,height:net.size.y),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    context.restoreGState()
  }
  override func draw(_ dirtyRect:NSRect) {
    NSColor(hex:"#E9EAE5").setFill();bounds.fill();hitPanels=[];hitPanelPaths=[]
    guard let context=NSGraphicsContext.current?.cgContext,let net,let store else {
      text(problem ?? "Choose a paper construction",at:.init(x:24,y:30));return
    }
    switch representation {
    case .panels:drawPanels(net,context:context,store:store)
    case .dieline:drawDieline(net,context:context,store:store)
    case .sheet:drawSheets(net,context:context,store:store)
    }
  }
  private func drawPanels(_ net:PaperNet,context:CGContext,store:StudioStore) {
    let columns=max(1,Int(bounds.width/210)),rows=Int(ceil(Double(net.panels.count)/Double(columns)))
    let cellWidth=(bounds.width-40)/Double(columns),cellHeight=min(240,max(115,(bounds.height-55)/Double(max(rows,1))))
    for (index,panel) in net.panels.enumerated() {
      let card=CGRect(x:20+Double(index%columns)*cellWidth+5,y:16+Double(index/columns)*cellHeight+5,width:cellWidth-10,height:cellHeight-10)
      context.setFillColor(NSColor(hex:"#F5F5F0").cgColor);context.addPath(CGPath(roundedRect:card,cornerWidth:10,cornerHeight:10,transform:nil));context.fillPath()
      let b=panel.bounds,scale=min((card.width-36)/max(1,b.width),(card.height-56)/max(1,b.height))
      let x=card.midX-b.width*scale/2,y=card.minY+12+(card.height-56-b.height*scale)/2
      context.saveGState();context.translateBy(x:x,y:y);context.scaleBy(x:scale,y:scale);context.translateBy(x:-b.x,y:-b.y)
      context.addPath(PaperOutput.path(panel.polygon));context.clip();drawImage(net:net,context:context);context.restoreGState()
      if store.paperSelectedPanelID==panel.id {context.setStrokeColor(NSColor(hex:"#C96543").cgColor);context.setLineWidth(2);context.addPath(CGPath(roundedRect:card.insetBy(dx:1,dy:1),cornerWidth:9,cornerHeight:9,transform:nil));context.strokePath()}
      text(panel.name,at:.init(x:card.minX+12,y:card.maxY-35),size:11,color:NSColor(hex:"#292D2B"))
      text(String(format:"%.1f × %.1f mm",b.width,b.height),at:.init(x:card.minX+12,y:card.maxY-20),size:9)
      hitPanels.append((card,panel.id))
    }
  }
  private func drawDieline(_ net:PaperNet,context:CGContext,store:StudioStore) {
    let scale=min((bounds.width-64)/net.size.x,(bounds.height-68)/net.size.y)
    guard scale>0 else{return}
    let x=(bounds.width-net.size.x*scale)/2,y=(bounds.height-net.size.y*scale)/2
    context.saveGState();context.translateBy(x:x,y:y);context.scaleBy(x:scale,y:scale)
    drawImage(net:net,context:context)
    if store.paperShowingGuides {PaperOutput.drawStructure(net,context:context,lineWidth:1/scale)}
    if let fold=net.folds.first(where:{$0.id==store.paperSelectedFoldID}) {
      context.setStrokeColor(NSColor(hex:"#C96543").cgColor);context.setLineWidth(2.5/scale)
      context.move(to:.init(x:fold.start.x,y:fold.start.y));context.addLine(to:.init(x:fold.end.x,y:fold.end.y));context.strokePath()
    }
    for panel in net.panels {
      let b=panel.bounds
      if panel.id==store.paperSelectedPanelID {context.addPath(PaperOutput.path(panel.polygon));context.setFillColor(NSColor(hex:"#C96543").withAlphaComponent(0.18).cgColor);context.fillPath()}
      hitPanels.append((.init(x:x+b.x*scale,y:y+b.y*scale,width:b.width*scale,height:b.height*scale),panel.id))
      var transform=CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:x,ty:y)
      if let path=PaperOutput.path(panel.polygon).copy(using:&transform) {hitPanelPaths.append((path,panel.id))}
    }
    context.restoreGState()
    text("CUT",at:.init(x:24,y:bounds.height-24),size:9,color:NSColor(hex:"#CA6543"));text("CREASE",at:.init(x:72,y:bounds.height-24),size:9,color:NSColor(hex:"#397D9A"));text("GLUE",at:.init(x:140,y:bounds.height-24),size:9,color:NSColor(hex:"#9B8056"))
  }
  private func drawSheets(_ net:PaperNet,context:CGContext,store:StudioStore) {
    guard let object,let definition=try? PaperConstruction.definition(for:object) else{return}
    do {
      let layout=try PaperOutput.layout(store:store,definition:definition)
      guard !layout.hasErrors,layout.sheetCount>0 else {text(layout.issues.map(\.message).joined(separator:" · "),at:.init(x:24,y:30));return}
      let showing=min(4,layout.sheetCount),columns=min(2,showing),rows=Int(ceil(Double(showing)/Double(columns)))
      let width=(bounds.width-48)/Double(columns),height=(bounds.height-64)/Double(rows)
      let scale=min((width-20)/layout.sheetSize.x,(height-28)/layout.sheetSize.y)
      guard scale>0 else{return}
      for i in 0..<showing {
        let x=24+Double(i%columns)*width+(width-layout.sheetSize.x*scale)/2,y=20+Double(i/columns)*height
        context.saveGState();context.translateBy(x:x,y:y);context.scaleBy(x:scale,y:scale)
        context.setShadow(offset:.init(width:0,height:2/scale),blur:8/scale,color:NSColor.black.withAlphaComponent(0.10).cgColor)
        context.setFillColor(NSColor.white.cgColor);context.fill(.init(x:0,y:0,width:layout.sheetSize.x,height:layout.sheetSize.y));context.setShadow(offset:.zero,blur:0,color:nil)
        for p in layout.placements where p.sheetIndex==i {
          context.saveGState();context.translateBy(x:p.origin.x,y:p.origin.y)
          if p.rotationDegrees != 0 {context.translateBy(x:net.size.y,y:0);context.rotate(by:p.rotationDegrees * .pi/180)}
          drawImage(net:net,context:context)
          if store.paperShowingGuides {PaperOutput.drawStructure(net,context:context,lineWidth:0.8/scale)}
          context.restoreGState()
        }
        context.restoreGState()
        text("Sheet \(i+1) · \(Int(layout.sheetSize.x)) × \(Int(layout.sheetSize.y)) mm",at:.init(x:x,y:y+layout.sheetSize.y*scale+7),size:10)
      }
      text("\(layout.count) prototypes · \(layout.sheetCount) sheets · no rotation · \(Int(layout.wasteFraction*100))% rectangular layout remainder",at:.init(x:24,y:bounds.height-26),size:10)
    } catch {text(error.localizedDescription,at:.init(x:24,y:30))}
  }
  override func mouseDown(with event:NSEvent) {
    let p=convert(event.locationInWindow,from:nil)
    let selected=representation == .dieline ? hitPanelPaths.last(where:{$0.0.contains(p)})?.1:hitPanels.last(where:{$0.0.contains(p)})?.1
    guard let object,let selected else{return}
    window?.makeFirstResponder(self);store?.activateDesignSurface(.artwork)
    store?.selectPaperPanel(objectID:object.id,panelID:selected)
    needsDisplay=true
    if event.clickCount==2 {store?.showPaper(.dieline,object:object);store?.showEnvironment(.form)}
  }
}
