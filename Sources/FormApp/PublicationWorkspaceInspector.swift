import AppKit
import FormCore
import FormGraphics
import FormCADModel
import SwiftUI
import UniformTypeIdentifiers

/// Explicit project ownership also guards existing document-level fields.
struct PublicationDocumentSettingsTarget {
  let projectID:UUID
  let documentID:UUID
  @MainActor @discardableResult
  func update(using controller:PublicationWorkspaceController,_ body:(inout PublicationDocument)->Void)->Bool {
    controller.update(documentID:documentID,expectedProjectID:projectID,body)
  }
}

/// Capture the actual metadata owner when a field is presented. Imported copies
/// may share document/page UUIDs; a stale blur/commit must not edit another project.
struct PublicationPageSettingsTarget:Hashable {
  let projectID:UUID
  let documentID:UUID
  let pageID:UUID
  let objectID:UUID
  init(projectID:UUID,documentID:UUID,page:PublicationPage) {
    self.projectID=projectID;self.documentID=documentID;pageID=page.id;objectID=page.objectID
  }
  @MainActor @discardableResult
  func update(using controller:PublicationWorkspaceController,_ body:(inout PublicationPage)->Void)->Bool {
    guard controller.project?.id==projectID,
      controller.project?.publications?.first(where:{$0.id==documentID})?.pages.contains(where:{$0.id==pageID && $0.objectID==objectID})==true else{return false}
    return PublicationDocumentSettingsTarget(projectID:projectID,documentID:documentID).update(using:controller) {document in
      guard let index=document.pages.firstIndex(where:{$0.id==pageID && $0.objectID==objectID}) else{return}
      body(&document.pages[index])
    }
  }
}

/// The same source/physical controls are embedded by Canvas and Table inspectors.
/// Editing shared data updates its representations; navigation is always explicit.
struct PublicationWorkspaceInspector:View {
  @ObservedObject var session:ArtworkSession
  @ObservedObject var controller:PublicationWorkspaceController
  var publicationID:UUID?=nil
  @State private var pageSettingsExpanded=true
  @State private var chaptersExpanded=false
  @State private var mastersExpanded=false
  private var project:Project?{session.store?.project}
  private var document:PublicationDocument? {
    if let publicationID {return project?.publications?.first{$0.id==publicationID}}
    return controller.document ?? session.currentPublication
  }
  private func update(_ document:PublicationDocument,projectID:UUID,_ body:@escaping(inout PublicationDocument)->Void){
    _=PublicationDocumentSettingsTarget(projectID:projectID,documentID:document.id).update(using:controller,body)
  }
  var body:some View {
    if let project,let document {
      VStack(alignment:.leading,spacing:InspectorStyle.sectionSpacing) {
        VStack(alignment:.leading,spacing:10) {
          InspectorSectionHeader("PUBLICATION")
          PublicationCommittedField(title:"Publication name",value:document.name,allowsEmpty:false){name in update(document,projectID:project.id){$0.name=name}}.textFieldStyle(InspectorTextFieldStyle())
          HStack {
            Text("\(document.pages.count) pages · \(document.leafPairs().count) leaves").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            Spacer()
            WorkspaceToolbarButton("Open pages on Canvas",symbol:"arrow.up.left.square",identifier:"publication-inspector-open-pages"){
              session.store?.showSurface(.artwork);controller.open(document.id)
            }
          }
          Toggle("Facing pages",isOn:Binding(get:{document.layout?.facingPages==true},set:{value in update(document,projectID:project.id){if $0.layout==nil {$0.layout = .init()};$0.layout!.facingPages=value}})).inspectorToggle()
          if document.layout?.facingPages==true {
            InspectorRow("First page") {
              Picker("First page side",selection:Binding(get:{document.layout?.firstPageSide ?? .recto},set:{value in update(document,projectID:project.id){$0.layout?.firstPageSide=value}})){
                Text("Right / recto").tag(PublicationPageSide.recto);Text("Left / verso").tag(PublicationPageSide.verso)
              }.labelsHidden().pickerStyle(.menu).font(InspectorStyle.labelFont)
            }
            HStack(spacing:10) {
              ArtworkUnitField("Inside",value:document.layout?.innerMargin ?? document.margins.left,unit:.mm){value in update(document,projectID:project.id){$0.layout?.innerMargin=value}}
              ArtworkUnitField("Outside",value:document.layout?.outerMargin ?? document.margins.right,unit:.mm){value in update(document,projectID:project.id){$0.layout?.outerMargin=value}}
            }
          }
          DisclosureGroup("Margins & baseline") {
            VStack(spacing:8) {
              HStack(spacing:10) {
                ArtworkUnitField("Top",value:document.margins.top,unit:.mm){value in update(document,projectID:project.id){$0.margins.top=value}}
                ArtworkUnitField("Bottom",value:document.margins.bottom,unit:.mm){value in update(document,projectID:project.id){$0.margins.bottom=value}}
              }
              HStack(spacing:10) {
                ArtworkUnitField("Left",value:document.margins.left,unit:.mm){value in update(document,projectID:project.id){$0.margins.left=value}}
                ArtworkUnitField("Right",value:document.margins.right,unit:.mm){value in update(document,projectID:project.id){$0.margins.right=value}}
              }
              Toggle("Baseline grid",isOn:Binding(get:{document.baselineGrid != nil},set:{value in update(document,projectID:project.id){$0.baselineGrid=value ? .init():nil}})).inspectorToggle()
              if let grid=document.baselineGrid {
                HStack(spacing:10) {
                  ScalarArtworkField("Spacing",value:grid.spacing,unit:"pt"){value in update(document,projectID:project.id){$0.baselineGrid?.spacing=value}}
                  ScalarArtworkField("Origin",value:grid.origin,unit:"pt"){value in update(document,projectID:project.id){$0.baselineGrid?.origin=value}}
                }
              }
              Text("Margins define new body frames. Existing artwork keeps its physical coordinates.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            }.padding(.top,8)
          }.font(InspectorStyle.labelFont)
          numbering(document,projectID:project.id)
        }
        if let page=document.pages.first(where:{$0.objectID==session.objectID}) {
          InspectorDivider()
          selectedPage(page,document:document,project:project)
        }
        InspectorDivider()
        sources(document,project:project)
        InspectorDivider()
        masters(document,project:project)
        InspectorDivider()
        PublicationBindingControls(session:session,publicationID:document.id)
        InspectorDivider()
        PublicationOutputControls(session:session,controller:controller,project:project,document:document)
          .id("publication-output-"+project.id.uuidString+document.id.uuidString)
      }.font(InspectorStyle.labelFont)
    }
  }
  private func numbering(_ document:PublicationDocument,projectID:UUID)->some View {
    DisclosureGroup("Page labels") {
      VStack(spacing:8) {
        Picker("Number style",selection:Binding(get:{document.numbering?.style ?? .arabic},set:{style in update(document,projectID:projectID){if $0.numbering==nil {$0.numbering = .init()};$0.numbering!.style=style}})) {
          Text("1, 2, 3").tag(PublicationNumberStyle.arabic);Text("i, ii, iii").tag(PublicationNumberStyle.lowerRoman);Text("I, II, III").tag(PublicationNumberStyle.upperRoman);Text("a, b, c").tag(PublicationNumberStyle.lowerAlpha);Text("A, B, C").tag(PublicationNumberStyle.upperAlpha)
        }.pickerStyle(.menu)
        ScalarArtworkField("Start at",value:Double(document.numbering?.start ?? 1),unit:""){value in guard value.isFinite,value.rounded()==value,(1...999999).contains(value) else{throw FormError.invalid("Use a whole starting page number from1 to999999.")};update(document,projectID:projectID){if $0.numbering==nil {$0.numbering = .init()};$0.numbering!.start=Int(value)}}
        PublicationCommittedField(title:"Prefix",value:document.numbering?.prefix ?? "",allowsEmpty:true){value in update(document,projectID:projectID){if $0.numbering==nil {$0.numbering = .init()};$0.numbering!.prefix=value}}.textFieldStyle(InspectorTextFieldStyle())
      }.padding(.top,8)
    }.font(InspectorStyle.labelFont)
  }
  private func selectedPage(_ page:PublicationPage,document:PublicationDocument,project:Project)->some View {
    let target=PublicationPageSettingsTarget(projectID:project.id,documentID:document.id,page:page)
    return DisclosureGroup(isExpanded:$pageSettingsExpanded) {
      VStack(alignment:.leading,spacing:8) {
        InspectorRow("Label") {
          PublicationCommittedField(title:"Automatic",value:page.label ?? "",allowsEmpty:true){value in
            _=target.update(using:controller){$0.label=value.isEmpty ? nil:value}
          }.textFieldStyle(InspectorTextFieldStyle()).accessibilityIdentifier("publication-page-label")
        }
        Toggle("Override chapter",isOn:Binding(get:{page.chapterTitle != nil},set:{enabled in
          _=target.update(using:controller){$0.chapterTitle=enabled ? document.chapterTitle(for:page.objectID) ?? "":nil}
        })).inspectorToggle().accessibilityIdentifier("publication-page-chapter-override")
          .help("Turn off to inherit the previous chapter title. An empty override clears the running title.")
        if page.chapterTitle != nil {
          PublicationCommittedField(title:"Chapter title",value:page.chapterTitle ?? "",allowsEmpty:true){value in
            _=target.update(using:controller){$0.chapterTitle=value}
          }.textFieldStyle(InspectorTextFieldStyle()).accessibilityIdentifier("publication-page-chapter-title")
        }
        Toggle("Restart numbering",isOn:Binding(get:{page.numberOverride != nil},set:{enabled in
          _=target.update(using:controller){$0.numberOverride=enabled ? 1:nil}
        })).inspectorToggle().accessibilityIdentifier("publication-page-number-restart")
        if let number=page.numberOverride {
          ScalarArtworkField("Start at",value:Double(number),unit:"",accessibilityName:"Selected page number restart"){value in
            guard value.isFinite,value.rounded()==value,(1...999999).contains(value) else{throw FormError.invalid("Use a whole page number from 1 to 999999.")}
            _=target.update(using:controller){$0.numberOverride=Int(value)}
          }.accessibilityIdentifier("publication-page-number-value")
        }
        InspectorRow("Masters") {
          Picker("Page master assignment",selection:Binding(get:{page.masterIDs != nil},set:{explicit in
            _=target.update(using:controller){$0.masterIDs=explicit ? document.appliedMasters(for:page.objectID).map(\.id):nil}
          })) {
            Text("Automatic").tag(false)
            Text("Choose masters").tag(true)
          }.labelsHidden().inspectorPicker().accessibilityIdentifier("publication-page-master-policy")
        }
        if let selected=page.masterIDs {
          ForEach(document.masters ?? []) {master in
            Toggle(master.name,isOn:Binding(get:{selected.contains(master.id)},set:{enabled in
              _=target.update(using:controller){page in
                var ids=page.masterIDs ?? []
                if enabled {if !ids.contains(master.id){ids.append(master.id)}}else{ids.removeAll{$0==master.id}}
                page.masterIDs=ids
              }
            })).inspectorToggle().accessibilityIdentifier("publication-page-master-"+master.id.uuidString)
          }
          if selected.isEmpty {Text("No masters on this page").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
        }
      }.padding(.top,8)
    }label:{InspectorSectionHeader("PAGE "+(document.pageLabel(for:page.objectID) ?? "—"))}
      .font(InspectorStyle.labelFont).accessibilityIdentifier("publication-selected-page-settings").id(target)
  }
  private func sources(_ document:PublicationDocument,project:Project)->some View {
    let stories=(project.textStories ?? []).filter{$0.publicationID==document.id}
    return DisclosureGroup(isExpanded:$chaptersExpanded) {
      VStack(alignment:.leading,spacing:8) {
        HStack {Spacer();WorkspaceToolbarButton("Reflow stories",symbol:"arrow.triangle.2.circlepath",identifier:"publication-reflow"){controller.reflow()}}
        if stories.isEmpty {Text("Select a text frame to start a linked story, or add a chapter from the page rail.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
        ForEach(stories){story in
          let overset=project.resolvedTextStory(story.id).map{PublicationStoryLayout.composition($0).oversetRange.length} ?? 0
          WorkspaceNavigationRow(title:story.name,subtitle:overset>0 ? "Text extends beyond its frames":"\(story.frames.count) frames · \(StorySourceStatistics.words(story.text)) words",symbol:"text.alignleft",statusSymbols:overset>0 ? ["exclamationmark.triangle"]:[],accessibilityLabel:"Edit story "+story.name,identifier:"publication-story-"+story.id.uuidString){
            session.store?.showSurface(.artwork);controller.open(document.id);controller.openStory(story.id)
          }
        }
      }.padding(.top,8)
    }label:{InspectorSectionHeader("CHAPTERS & TEXT",subtitle:"\(stories.count) linked stories")}
      .font(InspectorStyle.labelFont).accessibilityIdentifier("publication-stories-disclosure")
  }
  private func masters(_ document:PublicationDocument,project:Project)->some View {
    DisclosureGroup(isExpanded:$mastersExpanded) {
      VStack(alignment:.leading,spacing:8) {
        HStack {Spacer();WorkspaceToolbarButton("Add master artwork",symbol:"plus",identifier:"publication-add-master"){controller.createMaster(documentID:document.id,expectedProjectID:project.id)}}
        ForEach(document.masters ?? []) {master in
          VStack(alignment:.leading,spacing:5) {
            WorkspaceNavigationRow(title:master.name,subtitle:master.side == .all ? "All pages":"\(master.side.rawValue.capitalized) pages",symbol:"rectangle.on.rectangle",accessibilityLabel:"Edit master "+master.name,identifier:"publication-master-"+master.id.uuidString){_=controller.focusMaster(master.sourceObjectID,publicationID:document.id)}
            HStack {
              Picker("Master sides",selection:Binding(get:{master.side},set:{value in update(document,projectID:project.id){doc in if let index=doc.masters?.firstIndex(where:{$0.id==master.id}) {doc.masters![index].side=value}}})){
                Text("All pages").tag(PublicationMasterSide.all);Text("Right pages").tag(PublicationMasterSide.recto);Text("Left pages").tag(PublicationMasterSide.verso)
              }.labelsHidden().pickerStyle(.menu)
              Spacer()
              Button("Remove"){update(document,projectID:project.id){$0.masters?.removeAll{$0.id==master.id};for index in $0.pages.indices {$0.pages[index].masterIDs?.removeAll{$0==master.id}}}}.buttonStyle(.borderless)
            }
          }
        }
        if document.masters?.isEmpty != false {Text("Master artwork stays editable on the Canvas and appears on every assigned page.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
      }.padding(.top,8)
    }label:{InspectorSectionHeader("MASTERS",subtitle:"\(document.masters?.count ?? 0) artwork sources")}
      .font(InspectorStyle.labelFont).accessibilityIdentifier("publication-masters-disclosure")
  }

}

struct PublicationBindingControls:View {
  @ObservedObject var session:ArtworkSession
  @EnvironmentObject private var observedStore:StudioStore
  let publicationID:UUID
  private var store:StudioStore?{observedStore}
  private var assemblies:[ProductObject]{store?.project?.tablePresentationObjects.filter{$0.sheetAssembly?.publicationID==publicationID} ?? []}
  private func configure(_ object:ProductObject,expectedProject:UUID,_ body:(inout SheetAssemblyDefinition)->Void){
    guard let store,var definition=store.project?.objects.first(where:{$0.id==object.id})?.sheetAssembly,store.project?.id==expectedProject else{return}
    body(&definition)
    let key="sheet-assembly-\(object.id)"
    do {try store.engine.edit("Updated sheet assembly",source:"Studio",coalescing:store.engine.isInteracting(with:key) ? key:nil){project in try SheetAssemblyCommands.configure(in:&project,objectID:object.id,definition:definition)};store.changed()}
    catch{store.error=error.localizedDescription}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:10) {
      InspectorSectionHeader("PHYSICAL SHEETS")
      if let store,let project=store.project {
        if assemblies.isEmpty {
          WorkspaceToolbarButton("Create linked physical sheets",symbol:"book.closed",showsTitle:true,identifier:"publication-create-binding"){
            do {session.canvas?.finishText();try store.engine.edit("Created linked physical sheets",source:"Studio"){project in _=try SheetAssemblyCommands.create(in:&project,definition:.init(publicationID:publicationID),name:project.publications?.first{$0.id==publicationID}?.name ?? "Sheet assembly")};store.changed()}
            catch{store.error=error.localizedDescription}
          }
        }
        ForEach(assemblies) {object in
          if let definition=object.sheetAssembly {
            let resolved=try? project.resolvedSheetAssembly(object)
            VStack(alignment:.leading,spacing:10) {
              HStack {
                Text(object.name).font(.system(size:11,weight:.medium)).lineLimit(1)
                Spacer()
                WorkspaceToolbarButton("Find physical sheets on Table",symbol:"cube.transparent",identifier:"publication-find-binding-"+object.id.uuidString){_=store.findOnTable(object.id)}
              }
              if let resolved {
                SheetPoseControls(openingDegrees:Binding(get:{definition.openingDegrees},set:{value in configure(object,expectedProject:project.id){$0.openingDegrees=value}}),
                  activeSpread:Binding(get:{definition.activeSpread},set:{value in configure(object,expectedProject:project.id){$0.activeSpread=value}}),
                  bendMM:Binding(get:{definition.bendMM},set:{value in configure(object,expectedProject:project.id){$0.bendMM=value}}),
                  document:project.publications?.first{$0.id==publicationID},leaves:resolved.leaves,
                  onEditingChanged:store.inspectorInteraction("sheet-assembly-\(object.id)"))
              }
              SheetFastenerControls(binding:Binding(get:{definition.binding ?? .init()},set:{value in configure(object,expectedProject:project.id){$0.binding=value}}))
              if let parents=definition.parentSheets,!parents.isEmpty {
                DisclosureGroup("Parent sheets (\(parents.count))") {
                  VStack(alignment:.leading,spacing:10) {
                    ForEach(Array(parents.enumerated()),id:\.element.id){ordinal,parent in
                      SheetParentStockControls(parent:Binding(get:{parent},set:{value in configure(object,expectedProject:project.id){model in
                        if let index=model.parentSheets?.firstIndex(where:{$0.id==value.id}) {model.parentSheets![index]=value}
                      }}),ordinal:ordinal,targetID:"sheet-parent-\(object.id)-\(parent.id)",
                        onEditingChanged:store.inspectorInteraction("sheet-assembly-\(object.id)"))
                    }
                  }.padding(.top,8)
                }.font(InspectorStyle.labelFont)
              }else{
                ArtworkUnitField("Leaf caliper",value:definition.stock.resolvedThicknessMM,unit:.mm){value in configure(object,expectedProject:project.id){model in
                  let old=model.stock.resolvedThicknessMM;model.stock.thicknessMM=value
                  if model.stock.plies != nil,old>0 {for index in model.stock.plies!.indices {model.stock.plies![index].thicknessMM *= value/old}}
                }}
              }
              if let resolved {Text("\(resolved.leaves.count) leaves · \(String(format:"%.2f",resolved.stackThicknessMM)) mm stack").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
              if !(definition.enclosure ?? []).isEmpty {
                DisclosureGroup("Enclosure panels (\(definition.enclosure!.count))") {
                  ForEach(definition.enclosure ?? []) {plane in
                    VStack(alignment:.leading,spacing:5) {
                      Text(plane.name).font(.system(size:11,weight:.medium))
                      ForEach(Array([plane.front,plane.back].compactMap{$0}.enumerated()),id:\.offset){_,face in
                        if let source=project.objects.first(where:{$0.id==face.sourceObjectID}) {
                          Button("Edit \(source.name)"){store.showSurface(.artwork);session.activate(source.id);session.canvas?.synchronize();_=session.canvas?.fit(frameIDs:[source.id])}.buttonStyle(InspectorActionStyle())
                        }
                      }
                      ArtworkUnitField("Panel caliper",value:plane.stock.resolvedThicknessMM,unit:.mm){value in configure(object,expectedProject:project.id){model in if let index=model.enclosure?.firstIndex(where:{$0.id==plane.id}) {model.enclosure![index].stock.thicknessMM=value}}}
                    }.padding(.top,8)
                  }
                }.font(InspectorStyle.labelFont)
              }
            }.disabled(object.locked)
          }
        }
      }
    }
  }
}
