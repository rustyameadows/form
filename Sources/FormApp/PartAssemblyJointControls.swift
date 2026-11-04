import FormCADModel
import FormCore
import SwiftUI

struct PartAssemblyJointControls:View {
  @EnvironmentObject var store:StudioStore
  @Binding var definition:PlanarConstructionDefinition
  let object:ProductObject
  let projectID:UUID?
  @State private var selectedID:String?
  @State private var selectedFastenerID:String?
  @State private var expanded=false
  private var parameters:[String]{definition.parameters.map(\.name)+Array((definition.derived ?? [:]).keys).sorted()}
  private var jointSelection:Binding<String?> {
    Binding(get:{selectedID},set:{id in
      selectedID=id;selectedFastenerID=nil
      guard let id,store.project?.id==projectID,store.primary?.id==object.id else{return}
      _=store.selectConstructionTarget(objectID:object.id,jointID:id)
    })
  }
  private var fastenerSelection:Binding<String?> {
    Binding(get:{selectedFastenerID},set:{id in
      selectedFastenerID=id
      guard let jointID=selectedID,store.project?.id==projectID,store.primary?.id==object.id else{return}
      let attachment=definition.jointAttachments?.first{$0.joinID==jointID && ($0.staples ?? []).contains{$0.id==id}}
      _=store.selectConstructionTarget(objectID:object.id,jointID:jointID,attachmentID:attachment?.id,fastenerDefinitionID:id)
    })
  }
  private var target:ConstructionTableTarget? {
    guard store.project?.id==projectID,store.primary?.id==object.id,store.constructionTableTarget?.ownerID==object.id else{return nil}
    return store.constructionTableTarget
  }
  var body:some View {
    DisclosureGroup("Joints & reinforcement",isExpanded:$expanded) {
      VStack(alignment:.leading,spacing:9) {
        Picker("Joint",selection:jointSelection) {
          Text("Choose a joint").tag(String?.none)
          ForEach(definition.joins){join in Text(join.name).tag(Optional(join.id))}
        }.inspectorPicker().accessibilityIdentifier("construction-selected-joint")
        if let id=selectedID,let selected=definition.joins.first(where:{$0.id==id}) {
          let attachments=(definition.jointAttachments ?? []).filter{$0.joinID==id}
          let fasteners=attachments.flatMap{$0.staples ?? []}
          if !fasteners.isEmpty {
            Picker("Fastener row",selection:fastenerSelection) {
              Text("All joint attachments").tag(String?.none)
              ForEach(fasteners){staple in Text(staple.id).tag(Optional(staple.id))}
            }.inspectorPicker().accessibilityIdentifier("construction-selected-fastener")
          }
          if target?.jointID==id,target?.fastenerDefinitionID==selectedFastenerID,let picked=target?.fastenerInstanceID {Text("Selected wire: "+picked+" · editing its shared row").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
          joint(selected)
          ForEach(attachments.filter{selectedFastenerID==nil || ($0.staples ?? []).contains{$0.id==selectedFastenerID}}){attachment in
            let binding=Binding(get:{definition.jointAttachments?.first{$0.id==attachment.id} ?? attachment},set:{value in if let i=definition.jointAttachments?.firstIndex(where:{$0.id==attachment.id}){definition.jointAttachments![i]=value}})
            PartAssemblyAttachmentControls(attachment:binding,definition:definition,parameters:parameters,selectedFastenerID:fastenerSelection)
            Button("Remove attachment plan"){definition.jointAttachments?.removeAll{$0.id==attachment.id};reconcile()}.buttonStyle(InspectorActionStyle())
          }
          Button("Add attachment plan") {
            if definition.jointAttachments==nil{definition.jointAttachments=[]}
            definition.jointAttachments!.append(.init(id:UUID().uuidString,joinID:id))
          }.buttonStyle(InspectorActionStyle())
          Button("Remove joint") {
            definition.joins.removeAll{$0.id==id};definition.jointAttachments?.removeAll{$0.joinID==id}
            if let indices=definition.production?.steps.indices {for i in indices{definition.production!.steps[i].jointIDs.removeAll{$0==id}}}
            selectedID=nil;selectedFastenerID=nil
          }.buttonStyle(InspectorActionStyle())
        }
        Button("Add joint") {addJoint()}.buttonStyle(InspectorActionStyle()).disabled(definition.panels.count<2 || definition.joins.count>=128)
      }.padding(.top,8)
    }.onAppear{reconcile();synchronizeTarget()}
      .onChange(of:target){_,_ in synchronizeTarget()}
      .onChange(of:definition){_,_ in reconcile()}
  }
  private func synchronizeTarget() {
    guard let target,definition.joins.contains(where:{$0.id==target.jointID}) else{return}
    selectedID=target.jointID
    selectedFastenerID=target.fastenerDefinitionID.flatMap{id in definition.jointAttachments?.contains(where:{$0.joinID==target.jointID && ($0.staples ?? []).contains{$0.id==id}})==true ? id:nil}
    expanded=true
  }
  private func reconcile() {
    if !definition.joins.contains(where:{$0.id==selectedID}) {selectedID=definition.joins.first?.id;selectedFastenerID=nil}
    if let id=selectedFastenerID,definition.jointAttachments?.contains(where:{$0.joinID==selectedID && ($0.staples ?? []).contains{$0.id==id}}) != true {selectedFastenerID=nil}
  }
  private func joint(_ selected:PlanarJoinDefinition)->some View {
    let value=Binding(get:{definition.joins.first{$0.id==selected.id} ?? selected},set:{replacement in if let index=definition.joins.firstIndex(where:{$0.id==selected.id}){definition.joins[index]=replacement}})
    return VStack(spacing:8) {
      PublicationCommittedField(title:"Joint name",value:value.wrappedValue.name,allowsEmpty:false){value.wrappedValue.name=$0}.textFieldStyle(InspectorTextFieldStyle())
      Picker("First face",selection:value.firstPanelID){ForEach(definition.panels,id:\.id){Text($0.name).tag($0.id)}}.inspectorPicker()
      Picker("Second face",selection:value.secondPanelID){ForEach(definition.panels,id:\.id){Text($0.name).tag($0.id)}}.inspectorPicker()
      SheetExpressionField(title:"Joint overlap",value:value.overlapMM,parameters:parameters)
      PublicationCommittedField(title:"Attachment intent",value:value.wrappedValue.kind,allowsEmpty:false){value.wrappedValue.kind=$0}.textFieldStyle(InspectorTextFieldStyle())
      Toggle("Joint enabled",isOn:Binding(get:{((try? value.wrappedValue.enabled.map(definition.number)) ?? 1)>0.5},set:{value.wrappedValue.enabled=CADScalar($0 ? 1:0)})).inspectorToggle()
      if let current=value.wrappedValue.enabled {
        SheetExpressionField(title:"Joint condition",value:Binding(get:{value.wrappedValue.enabled ?? current},set:{value.wrappedValue.enabled=$0}),parameters:parameters,unit:"")
      }
      PublicationCommittedField(title:"Joint notes",value:value.wrappedValue.notes,allowsEmpty:true){value.wrappedValue.notes=$0}.textFieldStyle(InspectorTextFieldStyle())
    }
  }
  private func addJoint() {
    guard definition.panels.count>=2 else{return}
    let id=UUID().uuidString
    definition.joins.append(.init(id:id,name:"Board joint",firstPanelID:definition.panels[0].id,secondPanelID:definition.panels[1].id,kind:"Declared attachment",overlapMM:0))
    selectedID=id;selectedFastenerID=nil
  }
}
private struct PartAssemblyAttachmentControls:View {
  @Binding var attachment:PlanarJointAttachmentDefinition
  let definition:PlanarConstructionDefinition
  let parameters:[String]
  @Binding var selectedFastenerID:String?
  private var join:PlanarJoinDefinition?{definition.joins.first{$0.id==attachment.joinID}}
  private func region(_ panelID:String?)->PlanarJointSurfaceRegion {
    .init(polygon:definition.panels.first{$0.id==panelID}?.polygon ?? [.init(0,0),.init(5,0),.init(5,5),.init(0,5)])
  }
  private var installation:PlanarAttachmentInstallation {
    let targets=Set([join?.firstPanelID,join?.secondPanelID].compactMap{$0}),ownership=(try? definition.componentPanels()) ?? [:]
    return .init(presentComponentIDs:ownership.filter{!Set($0.value).isDisjoint(with:targets)}.keys.sorted())
  }
  var body:some View {
    VStack(alignment:.leading,spacing:10) {
      Toggle("Attachment enabled",isOn:Binding(get:{((try? attachment.enabled.map(definition.number)) ?? 1)>0.5},set:{attachment.enabled=CADScalar($0 ? 1:0)})).inspectorToggle()
      if let enabled=attachment.enabled {
        SheetExpressionField(title:"Attachment condition",value:Binding(get:{attachment.enabled ?? enabled},set:{attachment.enabled=$0}),parameters:parameters,unit:"")
      }
      Toggle("Bonded regions",isOn:Binding(get:{attachment.adhesive != nil},set:{attachment.adhesive=$0 ? .init(identity:"Declared adhesive",firstRegion:region(join?.firstPanelID),secondRegion:region(join?.secondPanelID)):nil})).inspectorToggle()
      if let adhesive=attachment.adhesive {
        let bond=Binding(get:{attachment.adhesive ?? adhesive},set:{attachment.adhesive=$0})
        DisclosureGroup("Adhesive coverage") {
          VStack(spacing:8) {
            PublicationCommittedField(title:"Adhesive identity",value:bond.wrappedValue.identity,allowsEmpty:false){bond.wrappedValue.identity=$0}.textFieldStyle(InspectorTextFieldStyle())
            SheetExpressionField(title:"Bond layer",value:bond.thicknessMM,parameters:parameters)
            SheetExpressionField(title:"Coverage fraction",value:bond.coverage,parameters:parameters,unit:"")
            ConstructionJointRegionControls(region:bond.firstRegion,title:"First bonded face",parameters:parameters)
            ConstructionJointRegionControls(region:bond.secondRegion,title:"Second bonded face",parameters:parameters)
            ConstructionExclusionControls(exclusions:bond.firstExclusions,title:"First face exclusions",parameters:parameters)
            ConstructionExclusionControls(exclusions:bond.secondExclusions,title:"Second face exclusions",parameters:parameters)
          }.padding(.top,8)
        }
      }
      Toggle("Structural tape strip",isOn:Binding(get:{attachment.tape != nil},set:{attachment.tape=$0 ? .init(componentID:definition.components?.first?.id ?? "",firstRegion:region(join?.firstPanelID),secondRegion:region(join?.secondPanelID),widthMM:12,lengthMM:30,installation:installation):nil})).inspectorToggle()
      if let tape=attachment.tape {
        let value=Binding(get:{attachment.tape ?? tape},set:{attachment.tape=$0})
        DisclosureGroup("Tape piece & placement") {
          VStack(spacing:8) {
            Picker("Actual strip",selection:value.componentID){ForEach(definition.components ?? []){part in Text(part.name).tag(part.id)}}.inspectorPicker()
            Text("Tape is this real material cut piece. Its stock, folds, position and caliper are edited in Parts.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            SheetExpressionField(title:"Tape width",value:value.widthMM,parameters:parameters)
            SheetExpressionField(title:"Tape length",value:value.lengthMM,parameters:parameters)
            SheetExpressionField(title:"Tape overlap",value:value.overlapMM,parameters:parameters)
            SheetExpressionField(title:"Tape bond layer",value:value.bondThicknessMM,parameters:parameters)
            SheetExpressionField(title:"Start offset",value:value.endOffsetStartMM,parameters:parameters)
            SheetExpressionField(title:"End offset",value:value.endOffsetEndMM,parameters:parameters)
            Picker("Pattern length axis",selection:value.lengthAxis){Text("X").tag(PlanarTapeDefinition.Axis.x);Text("Y").tag(PlanarTapeDefinition.Axis.y)}.inspectorPicker()
            PublicationCommittedField(title:"Tape placement side",value:value.wrappedValue.side,allowsEmpty:false){value.wrappedValue.side=$0}.textFieldStyle(InspectorTextFieldStyle())
            ConstructionJointRegionControls(region:value.firstRegion,title:"First taped face",parameters:parameters)
            ConstructionJointRegionControls(region:value.secondRegion,title:"Second taped face",parameters:parameters)
            ConstructionInstallationControls(installation:value.installation,components:definition.components ?? [])
          }.padding(.top,8)
        }
      }
      ForEach(attachment.staples ?? []){staple in
        let value=Binding(get:{attachment.staples?.first{$0.id==staple.id} ?? staple},set:{v in if let i=attachment.staples?.firstIndex(where:{$0.id==staple.id}){attachment.staples![i]=v}})
        ConstructionStapleControls(staple:value,definition:definition,parameters:parameters,isExpanded:Binding(get:{selectedFastenerID==staple.id},set:{expanded in selectedFastenerID=expanded ? staple.id:nil}))
        Button("Remove staple row"){attachment.staples?.removeAll{$0.id==staple.id}}.buttonStyle(InspectorActionStyle())
      }
      Button("Add anchored staple row") {
        guard let join else{return}
        let bounds=(try? definition.net().panels.first{$0.id==join.firstPanelID}?.bounds) ?? .init(x:0,y:0,width:10,height:10)
        if attachment.staples==nil{attachment.staples=[]}
        attachment.staples!.append(.init(id:UUID().uuidString,entryPanelID:join.firstPanelID,receivingPanelID:join.secondPanelID,anchor:.init(CADScalar(bounds.x+bounds.width/2),CADScalar(bounds.y+bounds.height/2)),tool:"Declared joint stapler",installation:installation))
      }.buttonStyle(InspectorActionStyle())
      Text("Preview checks receiving material, entry and exit paths, edge distances, declared installation layers and tool access before this fastening can be accepted.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
    }.padding(10).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
  }
}

private struct ConstructionJointRegionControls:View {
  @Binding var region:PlanarJointSurfaceRegion
  let title:String
  let parameters:[String]
  var body:some View {
    DisclosureGroup(title) {
      VStack(spacing:8) {
        Picker("Contact side",selection:$region.side){Text("Front").tag(PaperFinishAssignment.Side.outside);Text("Back").tag(PaperFinishAssignment.Side.inside)}.inspectorPicker()
        Toggle("Cut-edge contact",isOn:Binding(get:{region.edgeIndex != nil},set:{region.edgeIndex=$0 ? 0:nil})).inspectorToggle()
        if let edge=region.edgeIndex {
          ScalarArtworkField("Edge number",value:Double(edge+1),unit:""){amount in
            guard amount.isFinite,amount.rounded()==amount,(1...128).contains(amount) else{throw FormError.invalid("Choose a whole polygon edge number from1 to128.")};region.edgeIndex=Int(amount)-1
          }
          Text("Edges follow the saved polygon order. Region coordinates are distance along the edge and through the stock.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        }
        SheetPolygonControls(points:$region.polygon,parameters:parameters)
      }.padding(.top,8)
    }
  }
}
private struct ConstructionExclusionControls:View {
  @Binding var exclusions:[[CADExpressionPoint2]]?
  let title:String
  let parameters:[String]
  var body:some View {
    DisclosureGroup(title) {
      VStack(spacing:8) {
        ForEach((exclusions ?? []).indices,id:\.self){i in
          SheetPolygonControls(points:Binding(get:{exclusions?.indices.contains(i)==true ? exclusions![i]:[]},set:{if exclusions?.indices.contains(i)==true{exclusions![i]=$0}}),parameters:parameters)
          Button("Remove exclusion"){if exclusions?.indices.contains(i)==true{exclusions?.remove(at:i)}}.buttonStyle(InspectorActionStyle())
        }
        Button("Add rectangular exclusion"){if exclusions==nil{exclusions=[]};exclusions!.append([.init(1,1),.init(3,1),.init(3,3),.init(1,3)])}.buttonStyle(InspectorActionStyle())
      }.padding(.top,8)
    }
  }
}
private struct ConstructionInstallationControls:View {
  @Binding var installation:PlanarAttachmentInstallation
  let components:[PlanarComponentDefinition]
  var body:some View {
    DisclosureGroup("Installation layers & order") {
      VStack(spacing:8) {
        ScalarArtworkField("Installation order",value:Double(installation.order),unit:""){value in guard value.isFinite,value.rounded()==value,(0...10000).contains(value) else{throw FormError.invalid("Use a bounded whole installation order.")};installation.order=Int(value)}
        PublicationCommittedField(title:"Installation stage",value:installation.stage,allowsEmpty:false){installation.stage=$0}.textFieldStyle(InspectorTextFieldStyle())
        ForEach(components){component in
          Toggle("Present · "+component.name,isOn:Binding(get:{installation.presentComponentIDs.contains(component.id)},set:{enabled in
            installation.presentComponentIDs.removeAll{$0==component.id};if enabled{installation.presentComponentIDs.append(component.id)}
          })).inspectorToggle()
          Toggle("Later covered by · "+component.name,isOn:Binding(get:{installation.coveredByComponentIDs?.contains(component.id)==true},set:{enabled in
            if installation.coveredByComponentIDs==nil{installation.coveredByComponentIDs=[]};installation.coveredByComponentIDs!.removeAll{$0==component.id};if enabled{installation.coveredByComponentIDs!.append(component.id)}
          })).inspectorToggle()
        }
      }.padding(.top,8)
    }
  }
}
private struct ConstructionStapleControls:View {
  @Binding var staple:PlanarStapleDefinition
  let definition:PlanarConstructionDefinition
  let parameters:[String]
  @Binding var isExpanded:Bool
  var body:some View {
    DisclosureGroup("Anchored staple row",isExpanded:$isExpanded) {
      VStack(spacing:8) {
        Picker("Entry face",selection:$staple.entryPanelID){ForEach(definition.panels,id:\.id){Text($0.name).tag($0.id)}}.inspectorPicker()
        Picker("Receiving face",selection:$staple.receivingPanelID){ForEach(definition.panels,id:\.id){Text($0.name).tag($0.id)}}.inspectorPicker()
        Picker("Crown side",selection:$staple.entrySide){Text("Front").tag(PaperFinishAssignment.Side.outside);Text("Back").tag(PaperFinishAssignment.Side.inside)}.inspectorPicker()
        SheetExpressionField(title:"Staple anchor X",value:$staple.anchor.x,parameters:parameters)
        SheetExpressionField(title:"Staple anchor Y",value:$staple.anchor.y,parameters:parameters)
        SheetExpressionField(title:"Crown direction X",value:$staple.crownDirection.x,parameters:parameters,unit:"")
        SheetExpressionField(title:"Crown direction Y",value:$staple.crownDirection.y,parameters:parameters,unit:"")
        SheetExpressionField(title:"Crown width",value:$staple.crownWidthMM,parameters:parameters)
        SheetExpressionField(title:"Wire width",value:$staple.wireWidthMM,parameters:parameters)
        SheetExpressionField(title:"Wire depth",value:$staple.wireDepthMM,parameters:parameters)
        SheetExpressionField(title:"Leg length",value:$staple.legLengthMM,parameters:parameters)
        SheetExpressionField(title:"Staple count",value:$staple.count,parameters:parameters,unit:"")
        SheetExpressionField(title:"Staple spacing",value:$staple.spacingMM,parameters:parameters)
        SheetExpressionField(title:"End margin",value:$staple.endMarginMM,parameters:parameters)
        SheetExpressionField(title:"Receiving depth minimum",value:$staple.minimumReceivingDepthMM,parameters:parameters)
        SheetExpressionField(title:"Edge distance minimum",value:$staple.minimumEdgeDistanceMM,parameters:parameters)
        SheetExpressionField(title:"Joint gap maximum",value:$staple.maximumJointGapMM,parameters:parameters)
        Picker("Termination",selection:$staple.termination){ForEach(PlanarStapleDefinition.Termination.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}.inspectorPicker()
        if staple.termination == .clinch {
          SheetExpressionField(title:"Clinch length",value:Binding(get:{staple.clinchLengthMM ?? 2},set:{staple.clinchLengthMM=$0}),parameters:parameters)
          SheetExpressionField(title:"Clincher access",value:Binding(get:{staple.clincherAccessMM ?? 10},set:{staple.clincherAccessMM=$0}),parameters:parameters)
        }
        PublicationCommittedField(title:"Tool and access assumption",value:staple.tool,allowsEmpty:false){staple.tool=$0}.textFieldStyle(InspectorTextFieldStyle())
        SheetExpressionField(title:"Tool access",value:$staple.toolAccessMM,parameters:parameters)
        SheetExpressionField(title:"Tool clearance",value:$staple.toolClearanceMM,parameters:parameters)
        Toggle("Custom drive direction",isOn:Binding(get:{staple.driveDirection != nil},set:{staple.driveDirection=$0 ? .init(0,0,-1):nil})).inspectorToggle()
        if let direction=staple.driveDirection {
          let value=Binding(get:{staple.driveDirection ?? direction},set:{staple.driveDirection=$0})
          SheetExpressionField(title:"Drive X",value:value.x,parameters:parameters,unit:"")
          SheetExpressionField(title:"Drive Y",value:value.y,parameters:parameters,unit:"")
          SheetExpressionField(title:"Drive Z",value:value.z,parameters:parameters,unit:"")
        }
        Toggle("Custom row direction",isOn:Binding(get:{staple.spacingDirection != nil},set:{staple.spacingDirection=$0 ? .init(1,0):nil})).inspectorToggle()
        if let direction=staple.spacingDirection {
          let value=Binding(get:{staple.spacingDirection ?? direction},set:{staple.spacingDirection=$0})
          SheetExpressionField(title:"Row X",value:value.x,parameters:parameters,unit:"")
          SheetExpressionField(title:"Row Y",value:value.y,parameters:parameters,unit:"")
        }
        Menu("Additional crossed material layers") {
          ForEach((definition.components ?? []).filter{staple.installation.presentComponentIDs.contains($0.id)}){component in
            Toggle(component.name,isOn:Binding(get:{staple.layerComponentIDs?.contains(component.id)==true},set:{present in
              if staple.layerComponentIDs==nil{staple.layerComponentIDs=[]};staple.layerComponentIDs!.removeAll{$0==component.id};if present{staple.layerComponentIDs!.append(component.id)}
            }))
          }
        }.menuStyle(.borderlessButton)
        Text("Additional crossed layers must also be present during installation.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
        ConstructionInstallationControls(installation:$staple.installation,components:definition.components ?? [])
      }.padding(.top,8)
    }
  }
}
