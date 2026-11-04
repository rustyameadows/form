import FormCADModel
import FormCore
import SwiftUI

struct PartAssemblyPartsControls:View {
  @EnvironmentObject var store:StudioStore
  @Binding var definition:PlanarConstructionDefinition
  @Binding var componentID:String?
  let object:ProductObject
  let projectID:UUID?
  let canCreateArtwork:Bool
  let createArtwork:(String,PaperFinishAssignment.Side)->Void
  @State private var panelID:String?
  private var parameters:[String]{definition.parameters.map(\.name)+Array((definition.derived ?? [:]).keys).sorted()+["fold","opening","explosion"]}
  private var fallback:PaperStock{object.paperConstruction?.stock ?? .init()}
  private var tablePanelSelection:[String?] {[store.paperSelectionObjectID?.uuidString,store.paperSelectedPanelID]}
  private var selection:Binding<String?> {
    Binding(get:{componentID},set:{id in
      componentID=id;panelID=definition.components?.first{$0.id==id}?.rootPanelID
      if let id,let projectID {PartAssemblyNativeEditing.selectTablePart(store:store,projectID:projectID,objectID:object.id,componentID:id)}
    })
  }
  var body:some View {
    DisclosureGroup("Parts & parent groups") {
      VStack(alignment:.leading,spacing:9) {
        Picker("Selected cut piece",selection:selection) {
          Text("Choose a cut piece").tag(String?.none)
          ForEach(definition.components ?? []){part in Text(part.name).tag(Optional(part.id))}
        }.inspectorPicker().accessibilityIdentifier("construction-selected-part")
        if let id=componentID,let value=definition.components?.first(where:{$0.id==id}) {
          part(value).id(id)
        }
        Button("Add separate rectangular part"){addPart()}.buttonStyle(InspectorActionStyle()).disabled((definition.components?.count ?? 0)>=128)
        groups
      }.padding(.top,8)
    }.onAppear{synchronizeTableSelection()}
      .onChange(of:componentID){_,id in panelID=definition.components?.first{$0.id==id}?.rootPanelID}
      .onChange(of:tablePanelSelection){_,_ in synchronizeTableSelection()}
      .onChange(of:projectID){_,_ in synchronizeTableSelection()}
      .onChange(of:store.constructionTableTarget){_,_ in synchronizeTableSelection()}
  }
  private func synchronizeTableSelection() {
    guard store.project?.id==projectID else{return}
    if let target=store.constructionTableTarget,target.ownerID==object.id,let id=target.componentID,
      let part=definition.components?.first(where:{$0.id==id}) {componentID=id;panelID=part.rootPanelID;return}
    if store.paperSelectionObjectID==object.id,let panel=store.paperSelectedPanelID,
      let owners=try? definition.componentPanels(),let id=owners.first(where:{$0.value.contains(panel)})?.key {componentID=id;panelID=panel}
  }
  private func change(_ id:String,_ body:(inout PlanarComponentDefinition)->Void) {
    guard let index=definition.components?.firstIndex(where:{$0.id==id}) else{return}
    var value=definition;body(&value.components![index]);definition=value
  }
  @ViewBuilder private func part(_ value:PlanarComponentDefinition)->some View {
    let part=Binding(get:{definition.components?.first{$0.id==value.id} ?? value},set:{replacement in change(value.id){$0=replacement}})
    VStack(alignment:.leading,spacing:9) {
      PublicationCommittedField(title:"Part name",value:part.wrappedValue.name,allowsEmpty:false){name in change(value.id){$0.name=name}}.textFieldStyle(InspectorTextFieldStyle())
      PublicationCommittedField(title:"Purpose",value:part.wrappedValue.purpose ?? "",allowsEmpty:true){text in change(value.id){$0.purpose=text.isEmpty ? nil:text}}.textFieldStyle(InspectorTextFieldStyle())
      Picker("Parent group",selection:Binding<String?>(get:{part.wrappedValue.groupID},set:{id in change(value.id){$0.groupID=id}})) {
        Text("No parent group").tag(String?.none)
        ForEach(definition.groups ?? []){group in Text(group.name).tag(Optional(group.id))}
      }.inspectorPicker()
      Toggle("Part enabled",isOn:Binding(get:{(try? definition.componentEnabled(part.wrappedValue)) ?? true},set:{enabled in change(value.id){$0.enabled=CADScalar(enabled ? 1:0)}})).inspectorToggle()
      if let enabled=part.wrappedValue.enabled {
        SheetExpressionField(title:"Enabled condition",value:Binding(get:{part.wrappedValue.enabled ?? enabled},set:{scalar in change(value.id){$0.enabled=scalar}}),parameters:parameters,unit:"")
      }
      ScalarArtworkField("Quantity",value:Double(part.wrappedValue.quantity ?? 1),unit:""){amount in
        guard amount.isFinite,amount.rounded()==amount,(1...10000).contains(amount) else{throw FormError.invalid("Use 1–10000 whole pieces.")};change(value.id){$0.quantity=Int(amount)}
      }
      DisclosureGroup("Material stock") {
        VStack(spacing:8) {
          Toggle("Independent stock",isOn:Binding(get:{part.wrappedValue.stock != nil},set:{enabled in change(value.id){$0.stock=enabled ? fallback:nil}})).inspectorToggle()
          if let stock=part.wrappedValue.stock {
            SheetStockControls(stock:Binding(get:{part.wrappedValue.stock ?? stock},set:{stock in change(value.id){$0.stock=stock}}),targetID:"construction-part-stock-"+value.id,caliperIsDerived:part.wrappedValue.stockThickness != nil)
          }else{Text("Uses construction stock · "+fallback.name).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
          Toggle("Parameterized caliper",isOn:Binding(get:{part.wrappedValue.stockThickness != nil},set:{enabled in change(value.id){$0.stockThickness=enabled ? CADScalar((part.wrappedValue.stock ?? fallback).resolvedThicknessMM):nil}})).inspectorToggle()
          if let thickness=part.wrappedValue.stockThickness {
            SheetExpressionField(title:"Part caliper",value:Binding(get:{part.wrappedValue.stockThickness ?? thickness},set:{scalar in change(value.id){$0.stockThickness=scalar}}),parameters:parameters)
          }
          Menu("Copy material to…") {
            ForEach((definition.components ?? []).filter{$0.id != value.id}){target in
              Button(target.name){change(target.id){$0.stock=part.wrappedValue.stock ?? fallback}}
            }
          }.menuStyle(.borderlessButton)
        }.padding(.top,8)
      }
      DisclosureGroup("Assembly placement & pattern anchor") {
        VStack(spacing:8) {
          SheetExpressionField(title:"Position X",value:part.position.x,parameters:parameters)
          SheetExpressionField(title:"Position Y",value:part.position.y,parameters:parameters)
          SheetExpressionField(title:"Position Z",value:part.position.z,parameters:parameters)
          SheetExpressionField(title:"Rotation X",value:part.rotationDegrees.x,parameters:parameters,unit:"°")
          SheetExpressionField(title:"Rotation Y",value:part.rotationDegrees.y,parameters:parameters,unit:"°")
          SheetExpressionField(title:"Rotation Z",value:part.rotationDegrees.z,parameters:parameters,unit:"°")
          SheetExpressionField(title:"Pattern anchor X",value:part.anchor.x,parameters:parameters)
          SheetExpressionField(title:"Pattern anchor Y",value:part.anchor.y,parameters:parameters)
        }.padding(.top,8)
      }
      SheetSourceFaceControls(session:store.artworkSession,face:part.front,title:"Front artwork",parameters:parameters,onCreateArtwork:canCreateArtwork ? {createArtwork(value.id,.outside)}:nil)
      SheetSourceFaceControls(session:store.artworkSession,face:part.back,title:"Back artwork",parameters:parameters,onCreateArtwork:canCreateArtwork ? {createArtwork(value.id,.inside)}:nil)
      if !canCreateArtwork {Text("Apply these construction changes before creating another canonical artwork source.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      SheetPanelFinishControls(session:store.artworkSession,panel:finishProxy(part),onEditingChanged:{_ in})
      contours(value)
      Button("Find this piece on Canvas") {store.selectPaperPanel(objectID:object.id,panelID:value.rootPanelID);store.showPaper(.panels,object:object)}.buttonStyle(InspectorActionStyle())
      Button("Remove cut piece"){removePart(value.id)}.buttonStyle(InspectorActionStyle()).disabled((definition.components?.count ?? 0)<=1)
    }
  }
  private func finishProxy(_ part:Binding<PlanarComponentDefinition>)->Binding<SheetAssemblyPlane> {
    Binding(get:{let p=part.wrappedValue;let b=(try? definition.componentBounds(componentID:p.id)) ?? .init(x:0,y:0,width:1,height:1)
      return SheetAssemblyPlane(id:p.id,name:p.name,size:.init(CADScalar(b.width),CADScalar(b.height)),stock:p.stock ?? fallback,front:p.front,back:p.back,finishes:p.finishes)
    },set:{replacement in var p=part.wrappedValue;p.finishes=replacement.finishes;part.wrappedValue=p})
  }
  private func contours(_ component:PlanarComponentDefinition)->some View {
    DisclosureGroup("Cut pattern & connected faces") {
      VStack(alignment:.leading,spacing:8) {
        let owned=(try? definition.componentPanels()[component.id]) ?? []
        Picker("Pattern face",selection:Binding<String>(get:{panelID.flatMap{owned.contains($0) ? $0:nil} ?? component.rootPanelID},set:{panelID=$0})) {
          ForEach(definition.panels.filter{owned.contains($0.id)},id:\.id){panel in Text(panel.name).tag(panel.id)}
        }.inspectorPicker()
        if let selected=definition.panels.first(where:{$0.id==(panelID.flatMap{owned.contains($0) ? $0:nil} ?? component.rootPanelID)}) {
          let panel=Binding(get:{definition.panels.first{$0.id==selected.id} ?? selected},set:{replacement in if let i=definition.panels.firstIndex(where:{$0.id==selected.id}){definition.panels[i]=replacement}})
          PublicationCommittedField(title:"Face name",value:panel.wrappedValue.name,allowsEmpty:false){panel.wrappedValue.name=$0}.textFieldStyle(InspectorTextFieldStyle())
          SheetPolygonControls(points:panel.polygon,parameters:parameters)
          ForEach(panel.wrappedValue.cutouts ?? []){cutout in
            DisclosureGroup("Cutout · "+cutout.id) {
              SheetPolygonControls(points:Binding(get:{panel.wrappedValue.cutouts?.first{$0.id==cutout.id}?.polygon ?? cutout.polygon},set:{points in if let i=panel.wrappedValue.cutouts?.firstIndex(where:{$0.id==cutout.id}){panel.wrappedValue.cutouts![i].polygon=points}}),parameters:parameters)
              Button("Remove cutout"){panel.wrappedValue.cutouts?.removeAll{$0.id==cutout.id}}.buttonStyle(InspectorActionStyle())
            }
          }
          Button("Add rectangular cutout"){if let i=definition.panels.firstIndex(where:{$0.id==selected.id}){addCutout(i)}}.buttonStyle(InspectorActionStyle())
          if let hinge=definition.hinges.first(where:{$0.childPanelID==selected.id}) {
            SheetExpressionField(title:"Connected face angle",value:Binding(get:{definition.hinges.first{$0.id==hinge.id}?.angleDegrees ?? hinge.angleDegrees},set:{angle in if let i=definition.hinges.firstIndex(where:{$0.id==hinge.id}){definition.hinges[i].angleDegrees=angle}}),parameters:parameters,unit:"°")
          }
          Button("Add folded material face"){if let i=definition.panels.firstIndex(where:{$0.id==selected.id}){addConnectedFace(i)}}.buttonStyle(InspectorActionStyle()).disabled(definition.panels.count>=256 || !hasStraightRightEdge(selected))
          Text("Each connected face remains part of this one cut blank. New folded faces extend a straight right edge; separate boards use independent cut pieces and joints.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        }
      }.padding(.top,8)
    }
  }
  private var groups:some View {
    DisclosureGroup("Parent frames") {
      VStack(alignment:.leading,spacing:9) {
        ForEach(definition.groups ?? []){group in
          if let index=definition.groups?.firstIndex(where:{$0.id==group.id}) {
            let frame=Binding(get:{definition.groups?.first{$0.id==group.id} ?? group},set:{value in if let i=definition.groups?.firstIndex(where:{$0.id==group.id}){definition.groups![i]=value}})
            DisclosureGroup(group.name) {
              VStack(spacing:8) {
                PublicationCommittedField(title:"Group name",value:group.name,allowsEmpty:false){frame.wrappedValue.name=$0}.textFieldStyle(InspectorTextFieldStyle())
                Picker("Parent frame",selection:frame.parentID) {
                  Text("Root frame").tag(String?.none)
                  ForEach((definition.groups ?? []).filter{$0.id != group.id}){parent in Text(parent.name).tag(Optional(parent.id))}
                }.inspectorPicker()
                SheetExpressionField(title:"Group X",value:frame.position.x,parameters:parameters)
                SheetExpressionField(title:"Group Y",value:frame.position.y,parameters:parameters)
                SheetExpressionField(title:"Group Z",value:frame.position.z,parameters:parameters)
                SheetExpressionField(title:"Group rotation X",value:frame.rotationDegrees.x,parameters:parameters,unit:"°")
                SheetExpressionField(title:"Group rotation Y",value:frame.rotationDegrees.y,parameters:parameters,unit:"°")
                SheetExpressionField(title:"Group rotation Z",value:frame.rotationDegrees.z,parameters:parameters,unit:"°")
                Button("Remove empty group"){definition.groups?.removeAll{$0.id==group.id}}.buttonStyle(InspectorActionStyle())
                  .disabled(definition.components?.contains(where:{$0.groupID==group.id})==true || definition.groups?.contains(where:{$0.parentID==group.id})==true)
              }.padding(.top,8)
            }
          }
        }
        Button("Add parent group"){if definition.groups==nil{definition.groups=[]};definition.groups!.append(.init(id:UUID().uuidString,name:"Assembly group"))}.buttonStyle(InspectorActionStyle()).disabled((definition.groups?.count ?? 0)>=64)
      }.padding(.top,8)
    }
  }
  private func addPart() {
    guard let values=try? definition.resolvedValues() else{return}
    let ordinal=(definition.components?.count ?? 0)+1,id=UUID().uuidString,prefix="partExtent"+String(UUID().uuidString.prefix(8)).replacingOccurrences(of:"-",with:"")
    let old=definition.size.x.expression
    if definition.derived==nil{definition.derived=[:]};definition.derived![prefix]=CADScalar(old)
    let left=prefix+"+10",right=prefix+"+40"
    definition.panels.append(.init(id:id,name:"Cut piece \(ordinal)",polygon:[.init(CADScalar(left),0),.init(CADScalar(right),0),.init(CADScalar(right),30),.init(CADScalar(left),30)]))
    if definition.components==nil{definition.components=[]}
    definition.components!.append(.init(id:id,name:"Cut piece \(ordinal)",rootPanelID:id,anchor:.init(CADScalar(left),30),position:.init(0,0,0),rotationDegrees:.init(-90,0,0),stock:fallback,quantity:1))
    definition.size.x=CADScalar(prefix+"+50")
    let height=(try? CADExpression.evaluate(definition.size.y.expression,variables:values)) ?? 0
    if height<40 {definition.size.y=40}
    if definition.production?.materials.isEmpty==false {definition.production!.materials[0].componentIDs.append(id)}
    componentID=id;panelID=id
  }
  private func removePart(_ id:String) {
    let owned=Set((try? definition.componentPanels()[id]) ?? []),removedHinges=Set(definition.hinges.filter{owned.contains($0.childPanelID)}.map(\.id))
    let removedJoins=Set(definition.joins.filter{owned.contains($0.firstPanelID)||owned.contains($0.secondPanelID)}.map(\.id))
    definition.components?.removeAll{$0.id==id};definition.panels.removeAll{owned.contains($0.id)}
    definition.hinges.removeAll{owned.contains($0.childPanelID)||owned.contains($0.parentPanelID)}
    definition.joins.removeAll{removedJoins.contains($0.id)};definition.jointAttachments?.removeAll{removedJoins.contains($0.joinID)||$0.tape?.componentID==id}
    definition.connections?.removeAll{owned.contains($0.firstPanelID)||owned.contains($0.secondPanelID)}
    definition.solidChecks?.removeAll{owned.contains($0.firstPanelID)||owned.contains($0.secondPanelID)}
    definition.interiors?.removeAll{$0.componentID==id}
    if let indices=definition.production?.materials.indices {for i in indices{definition.production!.materials[i].componentIDs.removeAll{$0==id}}}
    definition.production?.materials.removeAll{$0.componentIDs.isEmpty};definition.production?.guides.removeAll{$0.componentID==id}
    for hinge in removedHinges{definition.production?.foldRoles.removeValue(forKey:hinge)}
    if let indices=definition.production?.steps.indices {for i in indices {
      definition.production!.steps[i].componentIDs.removeAll{$0==id};definition.production!.steps[i].jointIDs.removeAll{removedJoins.contains($0)}
    }}
    if owned.contains(definition.rootPanelID){definition.rootPanelID=definition.components?.first?.rootPanelID ?? definition.rootPanelID}
    componentID=definition.components?.first?.id;panelID=nil
  }
  private func addCutout(_ index:Int) {
    guard let net=try? definition.net(),let bounds=net.panels.first(where:{$0.id==definition.panels[index].id})?.bounds else{return}
    let x=bounds.x+bounds.width/3,y=bounds.y+bounds.height/3,w=bounds.width/3,h=bounds.height/3
    if definition.panels[index].cutouts==nil{definition.panels[index].cutouts=[]}
    definition.panels[index].cutouts!.append(.init(id:UUID().uuidString,polygon:[.init(CADScalar(x),CADScalar(y)),.init(CADScalar(x+w),CADScalar(y)),.init(CADScalar(x+w),CADScalar(y+h)),.init(CADScalar(x),CADScalar(y+h))]))
  }
  private func hasStraightRightEdge(_ panel:PlanarPanelDefinition)->Bool {
    guard let values=try? definition.resolvedValues() else{return false}
    let points=panel.polygon.compactMap{p -> Point2? in guard let x=try? CADExpression.evaluate(p.x.expression,variables:values),let y=try? CADExpression.evaluate(p.y.expression,variables:values) else{return nil};return .init(x,y)}
    guard points.count==panel.polygon.count,let right=points.map(\.x).max() else{return false}
    return points.indices.contains {i in let j=(i+1)%points.count;return abs(points[i].x-right)<1e-7 && abs(points[j].x-right)<1e-7 && abs(points[i].y-points[j].y)>1e-6}
  }
  private func addConnectedFace(_ index:Int) {
    guard let values=try? definition.resolvedValues() else{return}
    let original=definition.panels[index],points=original.polygon
    let resolved=points.compactMap{p -> Point2? in
      guard let x=try? CADExpression.evaluate(p.x.expression,variables:values),let y=try? CADExpression.evaluate(p.y.expression,variables:values) else{return nil};return .init(x,y)
    }
    guard resolved.count==points.count,let right=resolved.map(\.x).max(),let edge=resolved.indices.first(where:{i in let j=(i+1)%resolved.count;return abs(resolved[i].x-right)<1e-7 && abs(resolved[j].x-right)<1e-7 && abs(resolved[i].y-resolved[j].y)>1e-6}) else{return}
    let next=(edge+1)%points.count,a=resolved[edge].y<resolved[next].y ? points[edge]:points[next],b=resolved[edge].y<resolved[next].y ? points[next]:points[edge]
    let id=UUID().uuidString,hingeID=UUID().uuidString,rightExpression="(\(a.x.expression))+20"
    definition.panels.append(.init(id:id,name:"Connected material face",polygon:[a,.init(CADScalar(rightExpression),a.y),.init(CADScalar(rightExpression),b.y),b]))
    definition.hinges.append(.init(id:hingeID,parentPanelID:original.id,childPanelID:id,start:a,end:b,angleDegrees:90))
    let extent="faceExtent"+String(UUID().uuidString.prefix(8));if definition.derived==nil{definition.derived=[:]};definition.derived![extent]=definition.size.x
    definition.size.x=CADScalar("max(\(extent),(\(rightExpression))+10)")
    if definition.production != nil{definition.production!.foldRoles[hingeID] = .fold}
    panelID=id
  }
}
