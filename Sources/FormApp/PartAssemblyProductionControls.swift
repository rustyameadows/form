import FormCADModel
import FormCore
import SwiftUI

struct PartAssemblyProductionControls:View {
  @EnvironmentObject var store:StudioStore
  @Binding var definition:PlanarConstructionDefinition
  let object:ProductObject
  let projectID:UUID?
  let exportsEnabled:Bool
  @State private var packetSummary:String?
  @State private var packetIssues:[ConstructionPacketIssue]=[]
  private var parameters:[String]{definition.parameters.map(\.name)+Array((definition.derived ?? [:]).keys).sorted()}
  private var production:Binding<ConstructionProductionDefinition> {
    Binding(get:{definition.production ?? .init()},set:{definition.production=$0;packetSummary=nil;packetIssues=[]})
  }
  var body:some View {
    DisclosureGroup("Construction files & material layouts") {
      VStack(alignment:.leading,spacing:9) {
        if definition.production==nil {
          Button("Set up construction files") {
            definition.production = .init(materials:[.init(id:UUID().uuidString,name:"Material sheets",componentIDs:definition.components?.map(\.id) ?? [])])
          }.buttonStyle(InspectorActionStyle())
        }else{
          ScalarArtworkField("Assembly quantity",value:Double(production.wrappedValue.quantity),unit:""){amount in
            guard amount.isFinite,amount.rounded()==amount,(1...1000).contains(amount) else{throw FormError.invalid("Use 1–1000 whole assemblies.")};production.wrappedValue.quantity=Int(amount)
          }
          Toggle("Technical labels",isOn:production.labels).inspectorToggle()
          Toggle("Registration marks",isOn:production.registrationMarks).inspectorToggle()
          ArtworkUnitField("Print bleed",value:production.wrappedValue.bleedMM,unit:.mm){production.wrappedValue.bleedMM=$0}
          Toggle("Declared cutter kerf",isOn:Binding(get:{production.wrappedValue.declaredKerfMM != nil},set:{production.wrappedValue.declaredKerfMM=$0 ? 0:nil})).inspectorToggle()
          if let kerf=production.wrappedValue.declaredKerfMM {ArtworkUnitField("Kerf assumption",value:kerf,unit:.mm){production.wrappedValue.declaredKerfMM=$0}}
          Text("Cut files retain nominal design geometry. The packet records declared process assumptions separately.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          materials
          steps
          guides
          assumptions
          PublicationCommittedField(title:"Process notes",value:production.wrappedValue.processNotes,allowsEmpty:true){production.wrappedValue.processNotes=$0}.textFieldStyle(InspectorTextFieldStyle())
          Button("Check construction files"){preflight()}.buttonStyle(InspectorActionStyle()).disabled(!exportsEnabled).accessibilityIdentifier("construction-packet-preflight")
          if let packetSummary{Text(packetSummary).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
          ForEach(Array(packetIssues.enumerated()),id:\.offset){_,item in
            Text(item.message+(item.pieceIDs.isEmpty ? "":" · "+item.pieceIDs.joined(separator:", "))).font(InspectorStyle.captionFont).foregroundStyle(item.severity == .error ? Color.orange:Palette.secondary)
          }
          if object.paperConstruction?.artworkReviewRequired==true {
            Text("Artwork registration needs review after the accepted construction change.").font(InspectorStyle.captionFont).foregroundStyle(.orange)
            Button("Artwork registration reviewed") {
              do {
                try requireCurrentProject()
                _=try store.engine.call("form_paper",arguments:["command":"configure","object_id":object.id.uuidString,"acknowledge_artwork":true],source:"Studio");store.changed();packetSummary=nil;packetIssues=[]
              }catch{store.error=error.localizedDescription}
            }.buttonStyle(InspectorActionStyle()).disabled(!exportsEnabled)
          }
          HStack {
            Button("SVG…"){export("svg")}.buttonStyle(InspectorActionStyle())
            Button("PDF…"){export("pdf")}.buttonStyle(InspectorActionStyle())
          }.disabled(!exportsEnabled)
          Button("Export construction packet…"){export("packet")}.buttonStyle(InspectorActionStyle()).disabled(!exportsEnabled).accessibilityIdentifier("construction-export-packet")
          if !exportsEnabled {Text("Apply the reviewed changes before exporting a new source revision.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
        }
      }.padding(.top,8)
    }.onChange(of:definition){_,_ in clearReview()}
      .onChange(of:object.paperConstruction){_,_ in clearReview()}
      .onChange(of:projectID){_,_ in clearReview()}
  }
  private var materials:some View {
    DisclosureGroup("Stock sheets & rolls") {
      VStack(alignment:.leading,spacing:9) {
        ForEach(production.wrappedValue.materials){format in
          let value=Binding(get:{production.wrappedValue.materials.first{$0.id==format.id} ?? format},set:{v in var source=production.wrappedValue;if let i=source.materials.firstIndex(where:{$0.id==format.id}){source.materials[i]=v;production.wrappedValue=source}})
          DisclosureGroup(format.name) {
            VStack(spacing:8) {
              PublicationCommittedField(title:"Stock layout name",value:value.wrappedValue.name,allowsEmpty:false){value.wrappedValue.name=$0}.textFieldStyle(InspectorTextFieldStyle())
              Picker("Stock format",selection:value.surface){ForEach(ConstructionStockFormat.Surface.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}.inspectorPicker()
              ArtworkUnitField("Stock width",value:value.wrappedValue.widthMM,unit:.mm){value.wrappedValue.widthMM=$0}
              ArtworkUnitField(value.wrappedValue.surface == .roll ? "Roll segment length":"Stock length",value:value.wrappedValue.lengthMM,unit:.mm){value.wrappedValue.lengthMM=$0}
              ArtworkUnitField("Sheet margin",value:value.wrappedValue.marginMM,unit:.mm){value.wrappedValue.marginMM=$0}
              ArtworkUnitField("Piece spacing",value:value.wrappedValue.spacingMM,unit:.mm){value.wrappedValue.spacingMM=$0}
              Picker("Grain constraint",selection:value.grain){ForEach(ConstructionStockFormat.Grain.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}.inspectorPicker()
              Toggle("Allow grain-respecting rotation",isOn:value.allowRotation).inspectorToggle()
              ScalarArtworkField("Waste allowance",value:value.wrappedValue.wasteAllowanceFraction*100,unit:"%"){value.wrappedValue.wasteAllowanceFraction=$0/100}
              Menu("Assigned cut pieces") {
                ForEach(definition.components ?? []){component in
                  Toggle(component.name,isOn:Binding(get:{value.wrappedValue.componentIDs.contains(component.id)},set:{enabled in
                    var source=production.wrappedValue
                    for i in source.materials.indices{source.materials[i].componentIDs.removeAll{$0==component.id}}
                    if enabled,let i=source.materials.firstIndex(where:{$0.id==format.id}){source.materials[i].componentIDs.append(component.id)}
                    production.wrappedValue=source
                  }))
                }
              }.menuStyle(.borderlessButton)
              Text("\(value.wrappedValue.componentIDs.count) source pieces; different physical stocks and calipers receive independent layouts.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
              Button("Remove stock layout"){production.wrappedValue.materials.removeAll{$0.id==format.id}}.buttonStyle(InspectorActionStyle())
            }.padding(.top,8)
          }
        }
        Button("Add stock sheet / roll") {
          let assigned=Set(production.wrappedValue.materials.flatMap(\.componentIDs)),available=(definition.components ?? []).map(\.id).filter{!assigned.contains($0)}
          production.wrappedValue.materials.append(.init(id:UUID().uuidString,name:"Material layout",componentIDs:available))
        }.buttonStyle(InspectorActionStyle()).disabled(production.wrappedValue.materials.count>=64)
      }.padding(.top,8)
    }
  }
  private var steps:some View {
    DisclosureGroup("Assembly instructions") {
      VStack(alignment:.leading,spacing:9) {
        ForEach(production.wrappedValue.steps){step in
          let value=Binding(get:{production.wrappedValue.steps.first{$0.id==step.id} ?? step},set:{v in if let i=production.wrappedValue.steps.firstIndex(where:{$0.id==step.id}){production.wrappedValue.steps[i]=v}})
          DisclosureGroup(step.title) {
            VStack(spacing:8) {
              PublicationCommittedField(title:"Step title",value:step.title,allowsEmpty:false){value.wrappedValue.title=$0}.textFieldStyle(InspectorTextFieldStyle())
              TextEditor(text:value.instructions).font(InspectorStyle.labelFont).foregroundStyle(Palette.ink).scrollContentBackground(.hidden).padding(6).frame(minHeight:90).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.moduleRadius))
              Menu("Part targets") {ForEach(definition.components ?? []){part in Toggle(part.name,isOn:arrayMembership(value.componentIDs,part.id))}}.menuStyle(.borderlessButton)
              Menu("Joint targets") {ForEach(definition.joins){joint in Toggle(joint.name,isOn:arrayMembership(value.jointIDs,joint.id))}}.menuStyle(.borderlessButton)
              Menu("After earlier steps") {
                ForEach(Array(production.wrappedValue.steps.prefix(while:{$0.id != step.id}))){earlier in Toggle(earlier.title,isOn:arrayMembership(value.after,earlier.id))}
              }.menuStyle(.borderlessButton)
              Button("Remove step") {
                production.wrappedValue.steps.removeAll{$0.id==step.id}
                for i in production.wrappedValue.steps.indices{production.wrappedValue.steps[i].after.removeAll{$0==step.id}}
              }.buttonStyle(InspectorActionStyle())
            }.padding(.top,8)
          }
        }
        Button("Add assembly step"){production.wrappedValue.steps.append(.init(id:UUID().uuidString,title:"Assembly step",instructions:"Describe the parts, attachment and inspection for this step."))}.buttonStyle(InspectorActionStyle())
      }.padding(.top,8)
    }
  }
  private func arrayMembership(_ values:Binding<[String]>,_ id:String)->Binding<Bool> {
    Binding(get:{values.wrappedValue.contains(id)},set:{enabled in values.wrappedValue.removeAll{$0==id};if enabled{values.wrappedValue.append(id)}})
  }
  private var assumptions:some View {
    DisclosureGroup("Declared assumptions") {
      VStack(alignment:.leading,spacing:8) {
        ForEach(production.wrappedValue.assumptions.indices,id:\.self){index in
          HStack {
            TextField("Assumption",text:Binding(get:{production.wrappedValue.assumptions.indices.contains(index) ? production.wrappedValue.assumptions[index]:""},set:{if production.wrappedValue.assumptions.indices.contains(index){production.wrappedValue.assumptions[index]=$0}}),axis:.vertical).textFieldStyle(InspectorTextFieldStyle())
            AppCloseButton("Remove assumption"){if production.wrappedValue.assumptions.indices.contains(index){production.wrappedValue.assumptions.remove(at:index)}}
          }
        }
        Button("Add construction assumption"){production.wrappedValue.assumptions.append("Declared material and process allowance; verify with the chosen stock.")}.buttonStyle(InspectorActionStyle())
      }.padding(.top,8)
    }
  }
  private var guides:some View {
    DisclosureGroup("Technical guides & process roles") {
      VStack(alignment:.leading,spacing:8) {
        ForEach(definition.hinges,id:\.id){hinge in
          Picker("Hinge · "+hinge.id,selection:Binding(get:{production.wrappedValue.foldRoles[hinge.id] ?? .fold},set:{production.wrappedValue.foldRoles[hinge.id]=$0})) {
            ForEach(ConstructionGuideRole.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}
          }.inspectorPicker()
        }
        ForEach(production.wrappedValue.guides){guide in
          let value=Binding(get:{production.wrappedValue.guides.first{$0.id==guide.id} ?? guide},set:{v in if let i=production.wrappedValue.guides.firstIndex(where:{$0.id==guide.id}){production.wrappedValue.guides[i]=v}})
          DisclosureGroup(guide.label.isEmpty ? guide.role.rawValue.capitalized:guide.label) {
            VStack(spacing:8) {
              PublicationCommittedField(title:"Guide label",value:guide.label,allowsEmpty:true){value.wrappedValue.label=$0}.textFieldStyle(InspectorTextFieldStyle())
              Picker("Guide piece",selection:value.componentID){ForEach(definition.components ?? []){Text($0.name).tag($0.id)}}.inspectorPicker()
              Picker("Guide role",selection:value.role){ForEach(ConstructionGuideRole.allCases,id:\.self){Text($0.rawValue.capitalized).tag($0)}}.inspectorPicker()
              Toggle("Closed guide",isOn:value.closed).inspectorToggle()
              ForEach(value.wrappedValue.points.indices,id:\.self){i in
                SheetExpressionField(title:"Guide point \(i+1) X",value:Binding(get:{value.wrappedValue.points.indices.contains(i) ? value.wrappedValue.points[i].x:0},set:{if value.wrappedValue.points.indices.contains(i){value.wrappedValue.points[i].x=$0}}),parameters:parameters)
                SheetExpressionField(title:"Guide point \(i+1) Y",value:Binding(get:{value.wrappedValue.points.indices.contains(i) ? value.wrappedValue.points[i].y:0},set:{if value.wrappedValue.points.indices.contains(i){value.wrappedValue.points[i].y=$0}}),parameters:parameters)
              }
              Button("Add guide point"){value.wrappedValue.points.append(.init(0,0))}.buttonStyle(InspectorActionStyle())
              Button("Remove guide"){production.wrappedValue.guides.removeAll{$0.id==guide.id}}.buttonStyle(InspectorActionStyle())
            }.padding(.top,8)
          }
        }
        Button("Add pattern guide") {
          if let id=definition.components?.first?.id{production.wrappedValue.guides.append(.init(id:UUID().uuidString,componentID:id,role:.annotation,points:[.init(0,0),.init(10,0)],label:"Pattern guide"))}
        }.buttonStyle(InspectorActionStyle())
      }.padding(.top,8)
    }
  }
  private func preflight() {
    do {
      try requireCurrentProject()
      guard let project=store.project else{throw FormError.missing("Open the construction project before checking files.")}
      let model=try ConstructionPacketModel(project:project,object:object)
      packetIssues=model.issues
      packetSummary="\(model.pieces.count) cut pieces · \(model.layouts.batches.count) material layouts · \(model.issues.filter{$0.severity == .error}.count) blocking issues"
    }catch{packetSummary=error.localizedDescription;store.error=error.localizedDescription}
  }
  private func clearReview() {packetSummary=nil;packetIssues=[]}
  private func requireCurrentProject()throws {
    guard let project=store.project,project.id==projectID,
      project.objects.first(where:{$0.id==object.id})?.paperConstruction==object.paperConstruction else{throw FormError.invalid("The construction project or source changed. Reopen its controls before checking or exporting files.")}
  }
  private func export(_ format:String) {
    do {try requireCurrentProject();store.exportPaperDialog(object:object,format:format)}catch{store.error=error.localizedDescription}
  }
}
