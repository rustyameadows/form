import AppKit
import Combine
import FormCADModel
import FormCore
import SwiftUI

/// Read-only sections share the source used by production drawings. This window
/// remains independent of the document's camera, selection and editing history.
@MainActor final class ConstructionDrawingReviewPresenter:NSObject,NSWindowDelegate {
  private(set) var window:NSWindow?
  private var scope:AnyCancellable?
  func show(store:StudioStore,objectID:UUID) {
    guard let project=store.project,let object=project.objects.first(where:{$0.id==objectID}),
      object.paperConstruction?.authored?.version ?? 0 >= 4 else{return}
    let fresh=window==nil
    let target=window ?? NSWindow(contentRect:.init(x:0,y:0,width:1040,height:760),
      styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
    target.identifier = .init("lab.construction.review");target.title=object.name+" · Construction review"
    target.contentMinSize = .init(width:780,height:540);target.isReleasedWhenClosed=false;target.delegate=self
    target.contentViewController=NSHostingController(rootView:ConstructionDrawingReviewContent(store:store,
      projectID:project.id,objectID:objectID,onClose:{[weak self] in self?.close()}).labInterface())
    window=target
    let owner=project.id
    scope=store.objectWillChange.sink{[weak self,weak store] _ in DispatchQueue.main.async {
      if store?.project?.id != owner || store?.showingHome==true || store?.project?.objects.contains(where:{$0.id==objectID}) != true {self?.close()}
    }}
    if fresh {target.center()};target.makeKeyAndOrderFront(nil)
  }
  func close() {
    scope=nil;guard let target=window else{return};window=nil
    target.delegate=nil;target.contentViewController=nil;target.close()
  }
  func windowWillClose(_ notification:Notification) {
    guard let target=notification.object as? NSWindow,target===window else{return}
    scope=nil;window=nil;target.delegate=nil;target.contentViewController=nil
  }
}

@MainActor private struct ConstructionDrawingReviewContent:View {
  @ObservedObject var store:StudioStore
  let projectID:UUID,objectID:UUID
  var onClose:()->Void
  @State private var view=ConstructionDrawingView(id:"review",title:"Construction review")
  @State private var drawing:ConstructionResolvedDrawing?
  @State private var issue:String?
  @State private var selection="assembled"
  @State private var selectedGroup:String?
  private var object:ProductObject? {store.project?.id==projectID ? store.project?.objects.first{$0.id==objectID}:nil}
  private var source:PaperConstruction? {object?.paperConstruction}
  private var views:[ConstructionDrawingView] {
    let saved=source?.authored?.production?.views ?? []
    return saved.isEmpty ? ConstructionAssemblyDrawings.defaultViews():saved
  }
  var body:some View {
    VStack(spacing:0) {
      HStack(spacing:12) {
        Text("Construction review").font(.system(size:15,weight:.semibold))
        Spacer();AppCloseButton("Close construction review",keyEquivalent:"\u{1b}",action:onClose)
      }.padding(16)
      HStack(alignment:.top,spacing:0) {
        VStack(spacing:0) {
          ConstructionDrawingSurface(drawing:drawing).background(Palette.paper)
          if let drawing {
            HStack {
              let size=drawing.assembledDimensionsMM
              Text(String(format:"%.2f × %.2f × %.2f mm",size.x,size.y,size.z)).monospacedDigit()
              Spacer();Text("\(drawing.shapes.count) material faces")
            }.font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary).padding(12)
          }
          if let issue {Text(issue).font(InspectorStyle.captionFont).foregroundStyle(.orange).padding(12)}
        }
        ScrollView {
          VStack(alignment:.leading,spacing:InspectorStyle.sectionSpacing) {
            InspectorSectionHeader("ASSEMBLY & SECTIONS")
            Picker("Saved view",selection:$selection) {ForEach(views){Text($0.title).tag($0.id)}}.inspectorPicker()
            Picker("Projection",selection:$view.projection) {ForEach(ConstructionDrawingView.Projection.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}.inspectorPicker()
            Picker("Section",selection:Binding(get:{view.sectionAxis?.rawValue ?? "none"},set:{view.sectionAxis=ConstructionDrawingView.SectionAxis(rawValue:$0)})) {
              Text("Whole assembly").tag("none");Text("Across X").tag("x");Text("Across Z").tag("z")
            }.inspectorPicker()
            if view.sectionAxis != nil {
              ScalarArtworkField("Section offset",value:sectionOffset,unit:"mm") {view.sectionOffsetMM=CADScalar($0)}
            }
            Picker("Parts",selection:Binding(get:{selectedGroup ?? "all"},set:{selectedGroup=$0 == "all" ? nil:$0;updateScope()})) {
              Text("All active pieces").tag("all")
              ForEach(source?.authored?.groups ?? []){Text($0.name).tag($0.id)}
            }.inspectorPicker()
            ScalarArtworkField("Opening",value:view.openingPercent,unit:"%") {view.openingPercent=$0}
            ScalarArtworkField("Explosion",value:view.explosionPercent,unit:"%") {view.explosionPercent=$0}
            InspectorDivider()
            Text("Sections use the declared core and ply calipers. The 3D viewport shows covering bends, textures and finish relief.")
              .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          }.padding(InspectorStyle.panelPadding)
        }.frame(width:280).background(Palette.surface)
      }
    }.background(Palette.surface).onAppear{chooseView()}
      .onChange(of:selection){_,_ in chooseView()}
      .onChange(of:view){_,_ in refresh()}
      .onChange(of:source){_,_ in refresh()}
      .onChange(of:store.project?.id){_,id in if id != projectID {onClose()}}
  }
  private func chooseView() {if let selected=views.first(where:{$0.id==selection}){view=selected;selectedGroup=nil};refresh()}
  private var sectionOffset:Double {
    let values=(try? source?.authored?.poseValues(fold:100,opening:view.openingPercent,explosion:view.explosionPercent)) ?? [:]
    return (try? CADExpression.evaluate(view.sectionOffsetMM?.expression ?? "0",variables:values)) ?? 0
  }
  private func updateScope() {
    view.componentIDs=selectedGroup.map{group in (source?.authored?.components ?? []).filter{$0.groupID==group}.map(\.id)}
  }
  private func refresh() {
    do {guard let source else{throw FormError.missing("This construction is no longer available.")}
      drawing=try ConstructionAssemblyDrawings.resolve(source:source,view:view);issue=nil
    }catch{drawing=nil;issue=error.localizedDescription}
  }
}

private struct ConstructionDrawingSurface:NSViewRepresentable {
  let drawing:ConstructionResolvedDrawing?
  func makeNSView(context:Context)->ConstructionDrawingViewSurface {ConstructionDrawingViewSurface()}
  func updateNSView(_ view:ConstructionDrawingViewSurface,context:Context) {view.drawing=drawing;view.needsDisplay=true}
}
private final class ConstructionDrawingViewSurface:NSView {
  var drawing:ConstructionResolvedDrawing?
  override var isFlipped:Bool{true}
  override func draw(_ dirtyRect:NSRect) {
    guard let drawing,let context=NSGraphicsContext.current?.cgContext else{return}
    let b=drawing.bounds,area=bounds.insetBy(dx:28,dy:28)
    guard area.width>0,area.height>0 else{return}
    let scale=min(area.width/b.width,area.height/b.height)
    context.saveGState();defer{context.restoreGState()}
    context.translateBy(x:area.midX-b.width*scale/2,y:area.midY-b.height*scale/2)
    context.scaleBy(x:scale,y:scale);context.translateBy(x:-b.x,y:-b.y)
    for shape in drawing.shapes {
      let path=CGMutablePath()
      for ring in [shape.points]+shape.holes {
        guard let first=ring.first else{continue};path.move(to:.init(x:first.x,y:first.y))
        for p in ring.dropFirst(){path.addLine(to:.init(x:p.x,y:p.y))};if shape.closed {path.closeSubpath()}
      }
      context.addPath(path);context.setLineWidth(max(0.6/scale,shape.lineWidthMM))
      context.setFillColor(NSColor(hex:shape.color).cgColor)
      context.setStrokeColor(NSColor(hex:shape.closed ? "#303636":shape.color).cgColor)
      context.drawPath(using:shape.closed ? .eoFillStroke:.stroke)
    }
  }
}
