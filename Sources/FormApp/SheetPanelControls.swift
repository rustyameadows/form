import AppKit
import FormCADModel
import FormCore
import SwiftUI

/// Generic authored planes: the same controls serve wrapped boards, flexible
/// covers, folders, cases and other dimensioned physical panels.
struct SheetPanelControls:View {
  @ObservedObject var session:ArtworkSession
  @Binding var panel:SheetAssemblyPlane
  let objectID:UUID
  var parameters:[String]=[]
  var onEditingChanged:(Bool)->Void = {_ in}
  private func features(_ change:(inout SheetPanelFeatures)->Void) {
    var value=panel;var detail=value.features ?? .init();change(&detail);value.features=detail;panel=value
  }
  var body:some View {
    VStack(alignment:.leading,spacing:9) {
      PublicationCommittedField(title:"Panel name",value:panel.name,allowsEmpty:false){panel.name=$0}.textFieldStyle(InspectorTextFieldStyle())
      SheetExpressionField(title:"Width",value:$panel.size.x,parameters:parameters)
      SheetExpressionField(title:"Height",value:$panel.size.y,parameters:parameters)
      DisclosureGroup("Position & rotation") {
        VStack(spacing:8) {
          SheetExpressionField(title:"Position X",value:$panel.positionMM.x,parameters:parameters)
          SheetExpressionField(title:"Position Y",value:$panel.positionMM.y,parameters:parameters)
          SheetExpressionField(title:"Position Z",value:$panel.positionMM.z,parameters:parameters)
          SheetExpressionField(title:"Rotation X",value:$panel.rotationDegrees.x,parameters:parameters,unit:"°")
          SheetExpressionField(title:"Rotation Y",value:$panel.rotationDegrees.y,parameters:parameters,unit:"°")
          SheetExpressionField(title:"Rotation Z",value:$panel.rotationDegrees.z,parameters:parameters,unit:"°")
        }.padding(.top,8)
      }
      DisclosureGroup("Core material stock") {
        SheetStockControls(stock:$panel.stock,targetID:"sheet-panel-stock-"+panel.id,caliperIsDerived:panel.features?.stockThickness != nil,onEditingChanged:onEditingChanged).padding(.top,8)
      }
      Toggle("Parameterized caliper",isOn:Binding(get:{panel.features?.stockThickness != nil},set:{enabled in
        features{$0.stockThickness=enabled ? CADScalar(panel.stock.resolvedThicknessMM):nil}
      })).inspectorToggle()
      if let thickness=panel.features?.stockThickness {
        SheetExpressionField(title:"Core caliper",value:Binding(get:{panel.features?.stockThickness ?? thickness},set:{v in features{$0.stockThickness=v}}),parameters:parameters)
      }
      SheetSourceFaceControls(session:session,face:$panel.front,title:"Front artwork",parameters:parameters,onCreateArtwork:{createSource(side:.outside)})
      SheetSourceFaceControls(session:session,face:$panel.back,title:"Back artwork",parameters:parameters,onCreateArtwork:{createSource(side:.inside)})
      outline
      SheetWrappingControls(wrap:Binding(get:{panel.features?.wrap},set:{v in features{$0.wrap=v}}),parameters:parameters,targetID:"sheet-wrap-"+panel.id,onEditingChanged:onEditingChanged)
      flex
      recesses
      SheetPanelFinishControls(session:session,panel:$panel,onEditingChanged:onEditingChanged)
    }.font(InspectorStyle.labelFont)
  }
  private var outline:some View {
    DisclosureGroup("Outline & cutouts") {
      VStack(alignment:.leading,spacing:8) {
        Toggle("Custom outline",isOn:Binding(get:{panel.features?.outline != nil},set:{enabled in
          features{$0.outline=enabled ? [.init(0,0),.init(panel.size.x,0),panel.size,.init(0,panel.size.y)]:nil}
        })).inspectorToggle()
        if let outline=panel.features?.outline {
          SheetPolygonControls(points:Binding(get:{panel.features?.outline ?? outline},set:{v in features{$0.outline=v}}),parameters:parameters)
        }
        ForEach(panel.features?.cutouts ?? []){cutout in
          VStack(alignment:.leading,spacing:7) {
            HStack {Text("Cutout · "+cutout.id).lineLimit(1);Spacer();AppCloseButton("Remove cutout"){features{$0.cutouts?.removeAll{$0.id==cutout.id}}}}
            SheetPolygonControls(points:Binding(get:{panel.features?.cutouts?.first{$0.id==cutout.id}?.polygon ?? cutout.polygon},set:{polygon in
              features{if let i=$0.cutouts?.firstIndex(where:{$0.id==cutout.id}) {$0.cutouts![i].polygon=polygon}}
            }),parameters:parameters)
          }.padding(8).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
        }
        Button("Add rectangular cutout") {
          let w=panel.size.x.expression,h=panel.size.y.expression
          let points:[CADExpressionPoint2]=[.init(CADScalar("(\(w))/4"),CADScalar("(\(h))/4")),.init(CADScalar("(\(w))*3/4"),CADScalar("(\(h))/4")),.init(CADScalar("(\(w))*3/4"),CADScalar("(\(h))*3/4")),.init(CADScalar("(\(w))/4"),CADScalar("(\(h))*3/4"))]
          features{if $0.cutouts==nil {$0.cutouts=[]};$0.cutouts!.append(.init(id:UUID().uuidString,polygon:points))}
        }.buttonStyle(InspectorActionStyle())
      }.padding(.top,8)
    }
  }
  private var flex:some View {
    DisclosureGroup("Hinge & flex") {
      VStack(spacing:8) {
        Toggle("Flexible edge",isOn:Binding(get:{panel.features?.flex != nil},set:{enabled in
          features{$0.flex=enabled ? .init(widthMM:CADScalar("(\(panel.size.x.expression))/8")):nil}
        })).inspectorToggle()
        if let flex=panel.features?.flex {
          Picker("Flex edge",selection:Binding(get:{panel.features?.flex?.edge ?? flex.edge},set:{v in features{$0.flex?.edge=v}})) {
            ForEach(SheetPanelEdge.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}
          }.inspectorPicker()
          SheetExpressionField(title:flex.curve==nil ? "Hinge width":"Neutral length",value:Binding(get:{panel.features?.flex?.widthMM ?? flex.widthMM},set:{v in features{$0.flex?.widthMM=v}}),parameters:parameters)
          SheetExpressionField(title:"Flex angle",value:Binding(get:{panel.features?.flex?.angleDegrees ?? flex.angleDegrees},set:{v in features{$0.flex?.angleDegrees=v}}),parameters:parameters,unit:"°").disabled(flex.curve != nil)
          Toggle("Neutral curve",isOn:Binding(get:{panel.features?.flex?.curve != nil},set:{enabled in
            features{$0.flex?.curve=enabled ? .init(points:[.init(0,0),.init(CADScalar("(\(flex.widthMM.expression))/3"),0),.init(CADScalar("(\(flex.widthMM.expression))*2/3"),0),.init(flex.widthMM,0)]):nil;if enabled {$0.flex?.angleDegrees=0}}
          })).inspectorToggle()
          if let curve=panel.features?.flex?.curve {
            Toggle("Fit neutral material length",isOn:Binding(get:{panel.features?.flex?.curve?.fitLength ?? curve.fitLength},set:{v in features{$0.flex?.curve?.fitLength=v}})).inspectorToggle()
            Text("A cubic neutral path keeps artwork registered by material arc length. Length fitting adjusts the interior X handles while retaining the endpoints and height.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            ForEach(curve.points.indices,id:\.self){index in
              VStack(spacing:6) {
                SheetExpressionField(title:"Curve point \(index+1) X",value:Binding(get:{panel.features?.flex?.curve?.points[index].x ?? curve.points[index].x},set:{v in features{$0.flex?.curve?.points[index].x=v}}),parameters:parameters)
                SheetExpressionField(title:"Curve point \(index+1) Y",value:Binding(get:{panel.features?.flex?.curve?.points[index].y ?? curve.points[index].y},set:{v in features{$0.flex?.curve?.points[index].y=v}}),parameters:parameters)
              }.disabled(index==0)
            }
          }
        }
      }.padding(.top,8)
    }
  }
  private var recesses:some View {
    DisclosureGroup("Recesses & insets") {
      VStack(alignment:.leading,spacing:9) {
        ForEach(panel.features?.recesses ?? []){recess in
          SheetRecessControls(session:session,recess:Binding(get:{panel.features?.recesses?.first{$0.id==recess.id} ?? recess},set:{v in features{if let i=$0.recesses?.firstIndex(where:{$0.id==recess.id}) {$0.recesses![i]=v}}}),parameters:parameters,onEditingChanged:onEditingChanged,createArtwork:{createSource(side:.outside,recessID:recess.id)}){
            features{$0.recesses?.removeAll{$0.id==recess.id}}
          }
        }
        Button("Add stepped recess") {
          let w=panel.size.x.expression,h=panel.size.y.expression,t=panel.features?.stockThickness?.expression ?? String(panel.stock.resolvedThicknessMM)
          let recess=SheetPanelRecess(id:UUID().uuidString,origin:.init(CADScalar("(\(w))/4"),CADScalar("(\(h))/4")),size:.init(CADScalar("(\(w))/2"),CADScalar("(\(h))/2")),depthMM:CADScalar("(\(t))/2"))
          features{if $0.recesses==nil {$0.recesses=[]};$0.recesses!.append(recess)}
        }.buttonStyle(InspectorActionStyle())
      }.padding(.top,8)
    }
  }
  private func createSource(side:PaperFinishAssignment.Side,recessID:String?=nil) {
    guard let project=session.store?.project,let object=project.objects.first(where:{$0.id==objectID}),
      let resolved=try? project.resolvedSheetAssembly(object),let physical=resolved.enclosure.first(where:{$0.id==panel.id}) else{return}
    let margin=recessID==nil && side == .outside ? physical.features?.wrap.map{physical.stock.resolvedThicknessMM+$0.turnInMM} ?? 0:0
    let baseSize=recessID.flatMap{id in physical.features?.recesses.first{$0.id==id}?.size} ?? physical.size
    let size=Point2(baseSize.x+margin*2,baseSize.y+margin*2)
    let panelID=panel.id
    _=SheetAssemblySourceEditing.create(session:session,projectID:project.id,objectID:objectID,name:panel.name+(recessID != nil ? " / Inset":side == .inside ? " / Back":" / Front"),size:size){model,face in
      guard let index=model.enclosure?.firstIndex(where:{$0.id==panelID}) else{throw FormError.missing("The physical panel was removed. Choose a current surface.")}
      if let recessID {
        guard let i=model.enclosure![index].features?.recesses?.firstIndex(where:{$0.id==recessID}),model.enclosure![index].features!.recesses![i].insert != nil else{throw FormError.missing("The physical inset was removed. Choose a current surface.")}
        model.enclosure![index].features!.recesses![i].insert!.face=face
      }else if side == .inside {model.enclosure![index].back=face}else{var registered=face;if margin>0 {registered.sourceOriginMM = .init(CADScalar(margin),CADScalar(margin))};model.enclosure![index].front=registered}
    }
  }
}

struct SheetPolygonControls:View {
  @Binding var points:[CADExpressionPoint2]
  let parameters:[String]
  var body:some View {
    VStack(spacing:7) {
      ForEach(points.indices,id:\.self){index in
        VStack(spacing:5) {
          HStack {Text("Point \(index+1)").font(InspectorStyle.captionFont);Spacer();if points.count>3 {AppCloseButton("Remove polygon point"){points.remove(at:index)}}}
          SheetExpressionField(title:"X",value:$points[index].x,parameters:parameters)
          SheetExpressionField(title:"Y",value:$points[index].y,parameters:parameters)
        }
      }
      Button("Add edge point") {
        guard let a=points.last,let b=points.first else{return}
        points.append(.init(CADScalar("((\(a.x.expression))+(\(b.x.expression)))/2"),CADScalar("((\(a.y.expression))+(\(b.y.expression)))/2")))
      }.buttonStyle(InspectorActionStyle()).disabled(points.count>=128)
    }
  }
}

private struct SheetRecessControls:View {
  @ObservedObject var session:ArtworkSession
  @Binding var recess:SheetPanelRecess
  let parameters:[String]
  var onEditingChanged:(Bool)->Void
  var createArtwork:(()->Void)?=nil
  let remove:()->Void
  var body:some View {
    VStack(spacing:8) {
      HStack {Text("Physical inset").font(InspectorStyle.headingFont);Spacer();AppCloseButton("Remove physical inset",action:remove)}
      SheetExpressionField(title:"Inset X",value:$recess.origin.x,parameters:parameters)
      SheetExpressionField(title:"Inset Y",value:$recess.origin.y,parameters:parameters)
      SheetExpressionField(title:"Inset width",value:$recess.size.x,parameters:parameters)
      SheetExpressionField(title:"Inset height",value:$recess.size.y,parameters:parameters)
      SheetExpressionField(title:"Recess depth",value:$recess.depthMM,parameters:parameters)
      SheetExpressionField(title:"Inset radius",value:$recess.cornerRadiusMM,parameters:parameters)
      Toggle("Insert material",isOn:Binding(get:{recess.insert != nil},set:{recess.insert=$0 ? .init(stock:.init(thicknessMM:0.01)):nil})).inspectorToggle()
      if let insert=recess.insert {
        SheetStockControls(stock:Binding(get:{recess.insert?.stock ?? insert.stock},set:{recess.insert?.stock=$0}),targetID:"sheet-insert-"+recess.id,onEditingChanged:onEditingChanged)
        SheetSourceFaceControls(session:session,face:Binding(get:{recess.insert?.face},set:{recess.insert?.face=$0}),title:"Inset artwork",parameters:parameters,onCreateArtwork:createArtwork)
      }
    }.padding(10).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
  }
}

struct SheetPanelFinishControls:View {
  @ObservedObject var session:ArtworkSession
  @Binding var panel:SheetAssemblyPlane
  var onEditingChanged:(Bool)->Void
  @State private var kind:PaperFinishAssignment.Kind = .foil
  @State private var side:PaperFinishAssignment.Side = .outside
  private func artwork(_ side:PaperFinishAssignment.Side)->Artwork? {
    guard let project=session.store?.project,let face=side == .inside ? panel.back:panel.front,
      let source=project.objects.first(where:{$0.id==face.sourceObjectID}) else{return nil}
    return PaperConstruction.isPaper(source) ? project.paperArtwork(for:source,inside:face.sourceSide == .inside):project.editableArtwork(source)
  }
  private func update(_ finish:PaperFinishAssignment,_ edit:(inout PaperFinishAssignment)->Void) {
    var value=panel
    if let index=value.finishes?.firstIndex(where:{$0.id==finish.id}) {edit(&value.finishes![index]);panel=value}
  }
  var body:some View {
    DisclosureGroup("Artwork finishes") {
      VStack(alignment:.leading,spacing:8) {
        ForEach(panel.finishes ?? []){finish in
          VStack(spacing:8) {
            HStack {Text(finish.name).font(InspectorStyle.headingFont);Spacer();AppCloseButton("Remove finish"){panel.finishes?.removeAll{$0.id==finish.id}}}
            Toggle("Enabled",isOn:Binding(get:{finish.enabled},set:{v in update(finish){$0.enabled=v}})).inspectorToggle()
            if [.letterpress,.deboss,.foil].contains(finish.kind) {ArtworkUnitField("Impression",value:finish.depthMM,unit:.mm){v in update(finish){$0.depthMM=v}}}
            if [.emboss,.screenPrint,.foil].contains(finish.kind) {ArtworkUnitField("Relief",value:finish.heightMM,unit:.mm){v in update(finish){$0.heightMM=v}}}
            InspectorColorPicker("Finish color",selection:Binding(get:{Color(nsColor:NSColor(hex:finish.color ?? "#C6A458"))},set:{v in update(finish){$0.color=NSColor(v).hexString}}),supportsOpacity:false,targetID:"sheet-finish-"+finish.id.uuidString,onEditingChanged:onEditingChanged)
            ScalarArtworkField("Opacity",value:finish.opacity,unit:""){v in update(finish){$0.opacity=v}}
            ScalarArtworkField("Metallic",value:finish.metallic ?? (finish.kind == .foil ? 1:0),unit:""){v in update(finish){$0.metallic=v}}
            ScalarArtworkField("Roughness",value:finish.roughness ?? 0.4,unit:""){v in update(finish){$0.roughness=v}}
          }.padding(9).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
        }
        Picker("Finish type",selection:$kind){ForEach(PaperFinishAssignment.Kind.allCases,id:\.self){Text($0.rawValue).tag($0)}}.inspectorPicker()
        Picker("Finish face",selection:$side){Text("Front").tag(PaperFinishAssignment.Side.outside);Text("Back").tag(PaperFinishAssignment.Side.inside)}.inspectorPicker()
        if let art=artwork(side) {
          Menu("Apply to artwork") {
            ForEach(art.elements.filter{$0.parentID==nil}){element in
              Button(element.title){
                let finish=PaperFinishAssignment(name:kind.rawValue,kind:kind,side:side,elementIDs:[element.id],depthMM:[.letterpress,.deboss].contains(kind) ? 0.05:0,heightMM:kind == .emboss ? 0.05:0)
                if panel.finishes==nil {panel.finishes=[]};panel.finishes!.append(finish)
              }
            }
          }.menuStyle(.borderlessButton)
        }else{Text("Link surface artwork to assign a finish.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      }.padding(.top,8)
    }
  }
}
