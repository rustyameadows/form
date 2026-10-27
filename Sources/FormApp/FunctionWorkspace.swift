import AppKit
import FormCore
import SwiftUI

struct EnvironmentPageHeading:View {
  let eyebrow:String,title:String,detail:String
  var body:some View {
    VStack(alignment:.leading,spacing:7) {
      Text(eyebrow.uppercased()).font(.system(size:9,weight:.semibold)).tracking(1.8).foregroundStyle(Palette.secondary)
      Text(title).font(.system(size:26,design:.serif))
      if !detail.isEmpty {Text(detail).font(.system(size:11)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)}
    }
  }
}

/// A purpose-built technical bench. Its view choices never edit source or camera.
struct FunctionWorkspace:View {
  @EnvironmentObject var store:StudioStore
  private var representation:String {get{store.functionRepresentation} nonmutating set{store.functionRepresentation=newValue}}
  private var objects:[ProductObject] {store.project?.objects.filter{!$0.isCanvasWorkspace} ?? []}
  var body:some View {
    GeometryReader {g in
      HStack(spacing:0) {
        if g.size.width>1120 {componentTree.frame(width:205);Divider()}
        VStack(spacing:0) {
          HStack(alignment:.top) {
            EnvironmentPageHeading(eyebrow:"Function · structure, assembly & behavior",title:"How does it work?",detail:store.primary?.name ?? "Choose a component to develop its dimensions, construction and relationships.")
            Spacer(minLength:8)
            Menu {
              ForEach(objects) {object in Button(object.name){store.selectWorkingObject(object.id)}}
            } label:{Label("Component",systemImage:"square.stack.3d.up")}.fixedSize().accessibilityLabel("Choose Function component")
          }.padding(22)
          HStack(spacing:6) {
            ForEach(availableViews,id:\.self) {value in
              Button(value){representation=value}.buttonStyle(.plain).padding(.horizontal,12).padding(.vertical,7)
                .background(representation==value ? Color.white:.clear,in:RoundedRectangle(cornerRadius:6))
                .accessibilityLabel("Function "+value).accessibilityValue(representation==value ? "Selected":"")
            }
            Spacer()
            if let object=store.primary {Button("Edit appearance"){store.showEnvironment(.form);if PaperConstruction.isPaper(object){store.showPaper(.dieline,object:object,split:true)}}.buttonStyle(.plain).foregroundStyle(Palette.accent)}
          }.font(.system(size:11)).padding(.horizontal,22).padding(.bottom,14)
          Divider()
          stage.frame(maxWidth:.infinity,maxHeight:.infinity)
          constructionSummary.padding(16).background(Palette.paper)
        }.frame(minWidth:360,maxWidth:.infinity,maxHeight:.infinity)
        Divider()
        EnvironmentContextPanel()
      }.background(Palette.paper)
    }.onChange(of:store.primary?.id){_,_ in if !availableViews.contains(representation){representation="Assembly"}}
      .focusedValue(\.designSurface,.table)
  }
  private var availableViews:[String] {
    if let object=store.primary,PaperConstruction.isPaper(object){return ["Assembly","Dieline","Panels","Sheet layout"]}
    if let object=store.primary,let project=store.project,FabricEnvironmentContext(object:object,project:project)?.sourceID != nil{return ["Assembly","Pattern"]}
    return ["Assembly"]
  }
  @ViewBuilder private var stage:some View {
    if representation=="Assembly" {
      ZStack(alignment:.bottomLeading) {
        TableCanvas()
        ScrollView(.horizontal){CameraControls().padding(16)}.frame(height:76).clipped()
      }
    }else if let object=store.primary {
      if representation=="Pattern" {FabricPatternWorkspace(object:object)}
      else {PaperConstructionPreview(object:object,representation:representation=="Panels" ? .panels:representation=="Sheet layout" ? .sheet:.dieline)}
    }
  }
  private var componentTree:some View {
    ScrollView {
      VStack(alignment:.leading,spacing:14) {
        SectionLabel("CONSTRUCTION")
        ForEach(objects) {object in
          Button {store.selectWorkingObject(object.id)} label:{
            HStack(alignment:.top,spacing:9) {
              Image(systemName:store.project?.recipe(object.recipeID)?.symbol ?? "cube.transparent").frame(width:22)
              VStack(alignment:.leading,spacing:4) {Text(object.name).font(.system(size:11,weight:.medium));Text(store.project?.recipe(object.recipeID)?.name ?? object.recipeID).font(.system(size:9)).foregroundStyle(Palette.secondary)}
              Spacer(minLength:0)
            }.padding(10).background(store.primary?.id==object.id ? Palette.accent.opacity(0.08):.clear,in:RoundedRectangle(cornerRadius:7))
          }.buttonStyle(.plain).accessibilityLabel("Function component "+object.name)
          if object.id==store.primary?.id,PaperConstruction.isPaper(object),let net=try? PaperConstruction.definition(for:object).net() {
            ForEach(net.panels) {panel in
              Button {store.selectPaperPanel(objectID:object.id,panelID:panel.id)} label:{
                HStack {Image(systemName:panel.role == .glue ? "link":"rectangle");Text(panel.name);Spacer(minLength:0)}
                  .font(.system(size:10)).padding(.vertical,5).padding(.leading,33)
                  .foregroundStyle(store.paperSelectedPanelID==panel.id ? Palette.accent:Palette.secondary)
              }.buttonStyle(.plain).accessibilityLabel("Construction panel "+panel.name)
            }
          }
        }
      }.padding(16)
    }
  }
  @ViewBuilder private var constructionSummary:some View {
    if let object=store.primary,let d=try? PaperConstruction.definition(for:object),let net=try? d.net() {
      HStack(alignment:.top,spacing:20) {
        Label("\(net.panels.count) panels · \(net.folds.count) folds",systemImage:"point.3.connected.trianglepath.dotted")
        Label("\(net.joins.count) identified joins",systemImage:"link")
        Spacer(minLength:0)
        Label(d.stock.verified ? "Declared measured stock":"Stock assumptions · review required",systemImage:d.stock.verified ? "checkmark.circle":"exclamationmark.circle").foregroundStyle(Palette.secondary)
      }.font(.system(size:10)).fixedSize(horizontal:false,vertical:true)
    }else {HStack{Label("One source · physical dimensions",systemImage:"ruler");Spacer();Text("Construction controls follow the selected component.")}.font(.system(size:10)).foregroundStyle(Palette.secondary)}
  }
}
