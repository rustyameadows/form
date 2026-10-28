import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Purpose-specific context, derived from durable source rather than the current viewport/tool.
struct FabricEnvironmentContext {
  let objectID:UUID
  let sourceID:UUID?
  let pieceCount:Int,cutCount:Int,seamCount:Int
  let textile:TextileProduct?
  let decorations:[ProductObject]
  let preparationCount:Int,jobCount:Int
  static func applies(to object:ProductObject,in project:Project)->Bool {
    guard !PaperConstruction.isPaper(object),!object.isCanvasWorkspace else{return false}
    if object.isFlexibleSurface || object.textile != nil || TextileProduct.defaults(for:object.recipeID) != nil || object.clothAttachment != nil || object.patternAssemblyAttachment != nil {return true}
    return object.recipeID=="artboard" && project.editableArtwork(object)?.elements.contains{$0.sewingPiece != nil}==true
  }
  init?(object:ProductObject,project:Project) {
    guard Self.applies(to:object,in:project) else{return nil}
    objectID=object.id;textile=object.textile ?? TextileProduct.defaults(for:object.recipeID)
    let source:ProductObject?
    if let id=object.patternAssembly?.sourceObjectID {source=project.objects.first{$0.id==id}}
    else {let owner=project.artworkOwner(object);source=owner.artwork?.elements.contains{$0.sewingPiece != nil}==true ? owner:nil}
    sourceID=source?.id
    let pieces=source?.artwork?.elements.compactMap(\.sewingPiece) ?? []
    pieceCount=pieces.count;cutCount=pieces.reduce(0){$0+$1.cutQuantity};seamCount=source?.artwork?.sewingSeams?.count ?? 0
    decorations=project.objects.filter {candidate in
      candidate.textile?.attachment?.garmentID==object.id || candidate.clothAttachment?.surfaceObjectID==object.id || candidate.patternAssemblyAttachment?.surfaceObjectID==object.id
    }
    let related=Set([object.id]+[source?.id].compactMap{$0}+decorations.map(\.id))
    preparationCount=project.decorationPreparations?.filter{related.contains($0.objectID)}.count ?? 0
    jobCount=project.productionJobs?.filter{related.contains($0.objectID)}.count ?? 0
  }
  var fabricationRoutes:[FabricationDestination] {
    var routes:[FabricationDestination]=[]
    if sourceID != nil {routes += [.pattern,.layout]}
    if let textile {
      if textile.embroidery != nil || [.embroideredPatch,.directEmbroidery].contains(textile.process) {routes.append(.embroidery)}
      if [.directPrint,.printedPatch,.sewnLabel].contains(textile.process) {routes.append(.decoration)}
    }
    return routes+[.jobs,.collection]
  }
  static func sourceObject(for destination:FabricationDestination,object:ProductObject,project:Project)->ProductObject {
    if [.pattern,.layout].contains(destination),let context=Self(object:object,project:project),let id=context.sourceID,let source=project.objects.first(where:{$0.id==id}) {return source}
    return object
  }
}

extension StudioStore {
  /// Opening an existing source editor/review does not replace the selected assembled object.
  @discardableResult func activateFabricPatternSource(for id:UUID)->UUID? {
    guard let project,let object=project.objects.first(where:{$0.id==id}),let context=FabricEnvironmentContext(object:object,project:project),let source=context.sourceID else{return nil}
    let owner=project.id,selection=engine.selection
    finishArtworkEditing()
    guard self.project?.id==owner,let current=self.project?.objects.first(where:{$0.id==id}),FabricEnvironmentContext(object:current,project:self.project!)?.sourceID==source else{return nil}
    artworkSession.activate(source)
    artworkSession.linkedTargetID=source==id ? nil:id
    engine.selection=selection
    changed(save:false)
    return source
  }
  func editFabricPatternSourceOnCanvas(for id:UUID) {
    guard activateFabricPatternSource(for:id) != nil else{return}
    showEnvironment(.form)
    showingHome=false
    if surfaceLayout == .detached {
      canvasWindowController?.showWindow(nil)
      canvasWindowController?.window?.makeKeyAndOrderFront(nil)
    }else {mode = .artwork}
    changed(save:false)
  }
}

struct FabricEnvironmentControls:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  @State private var pieces=false
  @State private var seams=false
  @State private var fabrics=false
  @State private var stock=false
  private var context:FabricEnvironmentContext? {store.project.flatMap{FabricEnvironmentContext(object:object,project:$0)}}
  var body:some View {
    if let project=store.project,let context {
      ScrollView {
        VStack(alignment:.leading,spacing:18) {
          VStack(alignment:.leading,spacing:5) {
            Text(object.name).font(.system(size:18,design:.serif))
            Text(store.environment == .function ? "Construction source & relationships":"Cut, stitch & prepare")
              .font(.system(size:11)).foregroundStyle(Palette.secondary)
          }
          if store.environment == .function {construction(project,context)}
          else {fabrication(project,context)}
        }.padding(16)
      }
      .sheet(isPresented:$pieces) {FabricPatternConstructionSheet(session:store.artworkSession).environmentObject(store)}
      .sheet(isPresented:$seams) {SewingSeamEditor(session:store.artworkSession).environmentObject(store)}
      .sheet(isPresented:$fabrics) {TextileFabricLibrary().environmentObject(store)}
      .sheet(isPresented:$stock) {TextileProductionLibraryView().environmentObject(store)}
    }
  }
  @ViewBuilder private func construction(_ project:Project,_ context:FabricEnvironmentContext)->some View {
    if let sourceID=context.sourceID,let source=project.objects.first(where:{$0.id==sourceID}) {
      VStack(alignment:.leading,spacing:10) {
        SectionLabel("ORIGINAL PATTERN")
        Text(source.name).font(.system(size:12,weight:.medium))
        Text("\(context.pieceCount) pieces · \(context.cutCount) cut copies · \(context.seamCount) paired seams").font(.system(size:10)).foregroundStyle(Palette.secondary)
        Button("Pieces, allowances & grain…") {if store.activateFabricPatternSource(for:object.id) != nil {pieces=true}}
          .accessibilityLabel("Edit original fabric pieces allowances and grain")
        Button("Pair source seam edges…") {if store.activateFabricPatternSource(for:object.id) != nil {seams=true}}
          .disabled(source.locked).accessibilityLabel("Pair original fabric seam edges")
        Button("Edit source on Canvas") {store.editFabricPatternSourceOnCanvas(for:object.id)}
        if let artwork=source.artwork,let diagnostics=try? SewingPatterns.diagnostics(artwork) {
          ForEach(diagnostics,id:\.seam.id) {check in
            Label(check.seam.name+(check.isConclusive ? (check.matches ? " · matched":String(format:" · %.1f mm mismatch",check.difference)):" · needs measurement review"),systemImage:check.isConclusive && check.matches ? "checkmark.circle":"exclamationmark.circle")
              .font(.system(size:10)).foregroundStyle(check.isConclusive && check.matches ? Palette.secondary:Palette.accent).fixedSize(horizontal:false,vertical:true)
          }
        }
        if object.patternAssembly==nil {
          Button("Arrange source cloth assembly…") {store.createPatternAssembly(sourceID:sourceID)}.disabled(source.locked)
        }
      }.font(.system(size:11))
      Divider()
    }
    if object.patternAssembly != nil {PatternAssemblyInspector(object:object);Divider()}
    if object.isFlexibleSurface {ClothInspector(controller:store.cloth.preview,object:object);Divider()}
    if object.patternAssembly==nil,let recipe=project.recipe(object.recipeID),!recipe.parameters.isEmpty {
      VStack(alignment:.leading,spacing:12) {
        SectionLabel("CONSTRUCTION DIMENSIONS")
        ForEach(recipe.parameters) {ParameterControl(parameter:$0,object:object)}
      }.disabled(object.locked)
      Divider()
    }
    if let textile=context.textile {
      FabricConstructionDetails(object:object,spec:textile,project:project)
      if textile.kind == .garment,context.sourceID==nil {
        Text("This garment blank has declared dimensions and decoration regions. No original sewing pattern is associated with it.")
          .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
    }
    if !object.isFlexibleSurface,context.textile?.kind != .garment {ClothAttachmentInspector(object:object,project:project)}
    if context.sourceID==nil && object.isFlexibleSurface {
      Text("The saved rest surface and declared supports drive this study. Pattern seams are available when the object is derived from original pattern panels.")
        .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
    }
    Text("Edit fabric color, artwork and presentation in Form.").font(.system(size:10)).foregroundStyle(Palette.secondary)
  }
  @ViewBuilder private func fabrication(_ project:Project,_ context:FabricEnvironmentContext)->some View {
    VStack(alignment:.leading,spacing:9) {
      SectionLabel("PROCESS & OUTPUT")
      ForEach(context.fabricationRoutes) {destination in
        let enabled=destination.available(in:project,object:object)
        Button {store.presentFabrication(destination)} label:{Label(destination.title,systemImage:destination.symbol).frame(maxWidth:.infinity,alignment:.leading)}
          .buttonStyle(.borderless).font(.system(size:12)).disabled(!enabled)
      }
    }
    if !context.decorations.isEmpty {
      Divider();SectionLabel("ATTACHED DECORATIONS")
      ForEach(context.decorations) {decoration in Button {store.select(decoration.id)} label:{Label(decoration.name,systemImage:"link")}.buttonStyle(.borderless).font(.system(size:11))}
    }
    Divider()
    VStack(alignment:.leading,spacing:8) {
      SectionLabel("FABRIC & STOCK")
      let material=project.material(object.materialID)
      if let fabric=material.fabric {
        Text(material.name).font(.system(size:12,weight:.medium))
        Text([fabric.composition,fabric.weightGSM.map{String(format:"%.0f GSM",$0)},fabric.usableWidth.map{String(format:"%.0f mm usable roll",$0)},fabric.inventoryMeters.map{String(format:"%.1f m recorded",$0)}].compactMap{$0}.joined(separator:" · "))
          .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
        Text(fabric.specificationsVerified ? "Verified declared stock specification":"Stock specifications need physical verification").font(.system(size:9)).foregroundStyle(Palette.secondary)
      }else if let assembly=object.patternAssembly {
        ForEach(assembly.panels,id:\.panel) {panel in Text("\(panel.material.name) · \(panel.densityGSM,format:.number.precision(.fractionLength(0))) GSM").font(.system(size:10))}
      }else {Text("Assign fabric to original pattern pieces before arranging a material cutting layout.").font(.system(size:10)).foregroundStyle(Palette.secondary)}
      Button("Fabrics & roll inventory…") {fabrics=true}.font(.system(size:11))
      Button("Threads, trims & equipment…") {stock=true}.font(.system(size:11))
    }
    Divider();SectionLabel("PREPARATION RECORDS")
    Text("\(context.preparationCount) captured decoration preparations\n\(context.jobCount) production jobs for this source and its components").font(.system(size:10)).foregroundStyle(Palette.secondary)
    Text(context.sourceID != nil ? "Cutting outputs use the original flat pattern and its actual allowances. Cloth preview is not calibrated fit or machine control.":"Review the selected component's source and process before capturing an output packet. Studio stock remains a declaration.")
      .font(.system(size:10)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
  }
}

private struct FabricConstructionDetails:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject,spec:TextileProduct,project:Project
  private func update(_ change:(inout TextileProduct)->Void) {var next=spec;change(&next);do{store.update(object,["textile":try jsonObject(next)])}catch{store.error=error.localizedDescription}}
  var body:some View {
    VStack(alignment:.leading,spacing:10) {
      SectionLabel(spec.kind == .garment ? "BLANK DECLARATION":"COMPONENT CONSTRUCTION")
      Text(spec.measurementsVerified ? "Declared measurements verified":"Concept dimensions · verify a physical sample").font(.system(size:10)).foregroundStyle(Palette.secondary)
      if spec.kind != .garment {
        if object.recipeID != "textilePrint" {
          Picker("Process",selection:Binding(get:{spec.process},set:{value in update{$0.process=value}})) {
            ForEach(TextileProduct.Process.allCases.filter{$0 != .decoratedBlank && $0 != .directPrint},id:\.self) {Text($0.name).tag($0)}
          }
          TextField("Border construction",text:Binding(get:{spec.border ?? ""},set:{value in update{$0.border=value}})).textFieldStyle(.roundedBorder)
          TextField("Backing",text:Binding(get:{spec.backing ?? ""},set:{value in update{$0.backing=value}})).textFieldStyle(.roundedBorder)
          TextField("Join / attachment method",text:Binding(get:{spec.attachmentMethod ?? ""},set:{value in update{$0.attachmentMethod=value}})).textFieldStyle(.roundedBorder)
        }
        if let attachment=spec.attachment,let garment=project.objects.first(where:{$0.id==attachment.garmentID}) {
          Label(garment.name+" · "+attachment.zone.name,systemImage:"link").font(.system(size:10))
          Text(String(format:"Across %.1f / down %.1f mm · %.1f°",attachment.offset.x,attachment.offset.y,attachment.rotation)).font(.system(size:9)).foregroundStyle(Palette.secondary)
        }
      }else {
        TextField("Blank / product reference",text:Binding(get:{spec.blankName ?? ""},set:{value in update{$0.blankName=value}})).textFieldStyle(.roundedBorder)
        TextField("Declared size",text:Binding(get:{spec.size ?? ""},set:{value in update{$0.size=value}})).textFieldStyle(.roundedBorder)
      }
      TextField("Construction notes",text:Binding(get:{spec.notes ?? ""},set:{value in update{$0.notes=value}}),axis:.vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
    }.font(.system(size:11)).disabled(object.locked)
  }
}

private struct FabricPatternConstructionSheet:View {
  @EnvironmentObject var store:StudioStore
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var session:ArtworkSession
  private var pieces:[ArtworkElement] {session.art.elements.filter{$0.sewingPiece != nil}}
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      HStack {Text("Original fabric construction").font(.system(size:23,design:.serif));Spacer();Button("Done") {store.finishArtworkEditing();dismiss()}.keyboardShortcut(.cancelAction)}
      Text("Edit stitch boundaries, physical allowances, cut copies, grain, notches and notes. Source dimensions remain in millimeters.").font(.system(size:11)).foregroundStyle(Palette.secondary)
      HStack(alignment:.top,spacing:22) {
        ScrollView {VStack(alignment:.leading,spacing:8){ForEach(pieces) {piece in Button {session.choose([piece.id])} label:{Text(piece.sewingPiece!.name).frame(maxWidth:.infinity,alignment:.leading).padding(8).background(session.primary?.id==piece.id ? Palette.accent.opacity(0.1):.clear,in:RoundedRectangle(cornerRadius:5))}.buttonStyle(.plain)}}}.frame(width:185)
        ScrollView {if let element=session.primary,element.sewingPiece != nil {SewingPatternControls(session:session,element:element).disabled(session.object?.locked==true)}else{Text("Choose a source piece.").foregroundStyle(Palette.secondary)}}.frame(maxWidth:.infinity)
      }
    }.padding(24).frame(width:680,height:680).background(Palette.paper).onAppear{if session.primary?.sewingPiece==nil,let first=pieces.first {session.choose([first.id])}}
  }
}

/// Optional viewport header for the shared Canvas/Table shell; never changes the surface or camera.
struct FabricEnvironmentHeader:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  var body:some View {
    if let project=store.project,let context=FabricEnvironmentContext(object:object,project:project) {
      HStack(spacing:12) {
        Label(store.environment == .form ? "Fabric design":store.environment == .function ? "Fabric construction":"Fabric production",systemImage:store.environment == .function ? "point.3.connected.trianglepath.dotted":"scissors").font(.system(size:12,weight:.medium))
        Text(context.sourceID != nil ? "\(context.pieceCount) original pieces · \(context.seamCount) seams":context.textile?.process.name ?? "Saved cloth source").font(.system(size:10)).foregroundStyle(Palette.secondary)
        Spacer()
        if store.environment == .fabricate,context.sourceID != nil {Button("Cutting pattern…") {store.presentFabrication(.pattern)}.font(.system(size:11))}
      }.padding(.horizontal,24).frame(height:40).background(Palette.paper)
    }
  }
}

/// The technical and production canvases review the canonical cutting source, not a second drawing.
struct FabricPatternWorkspace:View {
  @EnvironmentObject var store:StudioStore
  let object:ProductObject
  var body:some View {
    if let project=store.project,let context=FabricEnvironmentContext(object:object,project:project),context.sourceID != nil {
      FabricPatternProofWorkspace(object:object,session:store.artworkSession)
        .id(project.id.uuidString+"/"+object.id.uuidString)
    }else {
      ContentUnavailableView("No original cutting pattern",systemImage:"scissors",description:Text("Choose an object with an associated flat pattern source."))
    }
  }
}

private struct FabricPatternProofWorkspace:View {
  @EnvironmentObject var store:StudioStore
  @ObservedObject var session:ArtworkSession
  let object:ProductObject
  @StateObject private var review=PhysicalDocumentController()
  @StateObject private var model:SewingPatternReviewModel
  @State private var sourceAvailable=false
  init(object:ProductObject,session:ArtworkSession) {
    self.object=object;self.session=session
    _model=StateObject(wrappedValue:SewingPatternReviewModel(session:session))
  }
  private var producing:Bool {store.environment == .fabricate}
  private var context:FabricEnvironmentContext? {store.project.flatMap{FabricEnvironmentContext(object:object,project:$0)}}
  var body:some View {
    VStack(alignment:.leading,spacing:0) {
      VStack(alignment:.leading,spacing:10) {
        HStack(spacing:12) {
          VStack(alignment:.leading,spacing:4) {
            Text(producing ? "PREPARE THE CUTTING PATTERN":"DEVELOP THE FABRIC CONSTRUCTION")
              .font(.system(size:9,weight:.semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
            Text(object.name).font(.system(size:18,weight:.medium,design:.serif)).lineLimit(1)
          }
          Spacer(minLength:8)
          Button("Edit source in Form") {store.editFabricPatternSourceOnCanvas(for:object.id)}.font(.system(size:11))
        }
        HStack(spacing:12) {
          Text(session.object?.name ?? "Original flat pattern").lineLimit(1)
          if let context {Text("\(context.pieceCount) pieces · \(context.cutCount) cut copies · \(context.seamCount) paired seams")}
          Spacer(minLength:0)
        }.font(.system(size:10)).foregroundStyle(Palette.secondary)
        if producing {
          Picker("Pattern output",selection:$model.tiled) {
            Text("Large format").tag(false);Text("Tiled sheets").tag(true)
          }.pickerStyle(.segmented).labelsHidden().frame(maxWidth:300).accessibilityLabel("Fabric pattern output")
        }else {
          Text("Black cut contour & notches · blue stitch boundary · gold grain & fold guides")
            .font(.system(size:10)).foregroundStyle(Palette.secondary)
        }
      }.padding(18).background(Palette.paper)
      Divider()
      HStack(alignment:.top,spacing:16) {
        if producing && model.tiled {
          ScrollView {
            SewingTileSettings(draft:model.draft,saved:model.hasSavedOptions,
              save:{NSApp.keyWindow?.makeFirstResponder(nil);model.saveOptions()},
              clear:{NSApp.keyWindow?.makeFirstResponder(nil);model.saveOptions(clear:true)})
          }.frame(width:225)
        }
        VStack(alignment:.leading,spacing:9) {
          if sourceAvailable,let proof=model.proof {
            PhysicalDocumentNavigation(controller:review)
            PhysicalDocumentCanvas(controller:review,data:proof,identifier:model.identity)
              .frame(maxWidth:.infinity,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:6))
          }else {
            ContentUnavailableView("No valid cutting proof",systemImage:"scissors",description:Text(model.error.isEmpty ? "The original cutting source is unavailable.":model.error))
              .frame(maxWidth:.infinity,maxHeight:.infinity)
          }
          Text(String(format:"%.1f × %.1f mm source · %d piece templates · %d pages",model.size.x,model.size.y,model.pieceCount,model.pageCount))
            .font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.secondary)
          if !model.error.isEmpty,model.proof != nil {Text(model.error).font(.system(size:11)).foregroundStyle(.red)}
          if !review.error.isEmpty {Text(review.error).font(.system(size:11)).foregroundStyle(.red)}
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
      }.padding(16).frame(maxWidth:.infinity,maxHeight:.infinity)
      Divider()
      VStack(alignment:.leading,spacing:10) {
        Text(producing
          ? (model.tiled ? "Print at 100% / Actual size. Verify the calibration page; trim between paired gutter ticks and butt matching edges. Sheet options change the document only when saved.":"Full-size physical proof. Print at 100% / Actual size and verify the 50 mm calibration square before cutting.")
          : "Review physical allowances, grain, notches and seam correspondence. Construction edits stay on the original pattern; preview navigation leaves the assembled object unchanged.")
          .font(.system(size:10)).foregroundStyle(Palette.secondary)
        if producing {
          HStack(spacing:10) {
            ForEach(model.tiled ? ["pdf"]:["pdf","svg","png"],id:\.self) {format in
              Button("Export "+(model.tiled ? "tiled PDF":format.uppercased())) {export(format)}.disabled(!sourceAvailable || model.proof==nil)
            }
            Spacer(minLength:0)
            Text("DPI").font(.system(size:10))
            TextField("Pattern export DPI",text:$model.dpi).textFieldStyle(.roundedBorder).frame(width:65)
          }.font(.system(size:11))
        }
      }.padding(16).background(Palette.paper)
    }.background(Palette.paper)
      .onAppear { _ = store.activateFabricPatternSource(for:object.id);synchronize() }
      .onChange(of:store.revision) {_,_ in synchronize()}
      .onChange(of:store.project?.id) {_,_ in synchronize()}
      .onChange(of:context?.sourceID) {_,_ in synchronize()}
      .onChange(of:session.objectID) {_,_ in synchronize()}
      .onChange(of:session.art) {_,_ in synchronize()}
      .onChange(of:store.environment) {_,_ in synchronize()}
      .onChange(of:model.tiled) {_,_ in synchronize()}
      .onChange(of:model.draft.values) {_,_ in synchronize()}
      .focusedValue(\.designSurface,.artwork)
  }
  private func synchronize() {
    guard store.environment == .function || store.environment == .fabricate,
      let source=context?.sourceID else {sourceAvailable=false;return}
    let target=source==object.id ? nil:object.id
    if session.objectID != source || session.linkedTargetID != target {
      guard store.activateFabricPatternSource(for:object.id)==source else {sourceAvailable=false;return}
    }
    sourceAvailable=true
    model.refresh()
    // Function always reviews the construction at its original physical size.
    if !producing,model.tiled {model.tiled=false;model.refresh()}
  }
  private func export(_ format:String) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    synchronize()
    guard sourceAvailable,model.proof != nil,let source=session.object,let projectID=store.project?.id else{return}
    let projectEpoch=store.artworkTransferProjectEpoch
    let panel=NSSavePanel()
    panel.nameFieldStringValue=source.name+(model.tiled ? "-sewing-pattern-tiled.":"-sewing-pattern.")+format
    panel.allowedContentTypes=[format=="pdf" ? .pdf:format=="svg" ? .svg:.png]
    guard panel.runModal() == .OK,let url=panel.url else{return}
    // Revalidate after the modal panel before exporting through the shared production path.
    guard store.project?.id==projectID,store.artworkTransferProjectEpoch==projectEpoch,
      store.project?.objects.contains(where:{$0.id==object.id})==true,context?.sourceID==source.id,session.objectID==source.id else{return}
    if model.export(format,path:url) {store.toast("Sewing pattern exported")}
  }
}
