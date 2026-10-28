import AppKit
import FormCore
import FormGraphics
import SwiftUI
import UniformTypeIdentifiers

extension ArtworkSession {
  var selectedTextStory:TextStory? {
    let id=canvas?.storyEditor?.storyID ?? primary?.storyFrame?.storyID
    return id.flatMap{id in store?.project?.textStories?.first{$0.id==id}}
  }
  var sourceTextElement:ArtworkElement? {selectedTextStory?.sourceElement ?? primary}
  var sourceTextElements:[ArtworkElement] {
    elements.map{element in (element.storyFrame?.storyID).flatMap{id in store?.project?.textStories?.first{$0.id==id}?.sourceElement} ?? element}
  }
  var currentPublication:PublicationDocument? {
    guard let project=store?.project else{return nil}
    if let id=selectedTextStory?.publicationID {return project.publications?.first{$0.id==id}}
    return project.publications?.first{$0.pages.contains{$0.objectID==objectID}}
  }
  @discardableResult func publicationEdit(_ label:String,_ body:(inout Project)throws->Void)->Bool {
    canvas?.finishText();guard let store else{return false}
    do {try store.engine.edit(label,source:"Studio",body);store.changed();return true}
    catch {store.error=error.localizedDescription;return false}
  }
  @discardableResult func editLinkedTextSources(_ body:(inout ArtworkElement)->Void)->Bool {
    guard elements.contains(where:{$0.storyFrame != nil}),let object,let store else{return false}
    canvas?.finishText();let selected=selection
    do {
      try store.engine.edit("Edited story typography",source:"Studio",coalescing:"artwork-\(object.id)") {project in
        guard var art=project.editableArtwork(object) else{return}
        let targets=art.swatchPaintTargets(for:selected);var stories=Set<UUID>()
        for i in art.elements.indices where targets.contains(art.elements[i].id) && art.elements[i].kind=="text" {
          if let id=art.elements[i].storyFrame?.storyID {
            guard stories.insert(id).inserted,let source=project.textStories?.first(where:{$0.id==id})?.sourceElement else{continue}
            var changed=source;body(&changed);try PublicationCommands.setSource(in:&project,storyID:id,source:changed)
          } else {body(&art.elements[i])}
        }
        try project.setArtwork(art,for:object.id)
      }
      store.changed()
    } catch {store.error=error.localizedDescription}
    return true
  }
  func focusStoryFrame(_ frame:StoryFrameID) {
    if let editor=canvas?.storyEditor {editor.focus(frame);canvas?.revealStoryPage(frame.objectID);return}
    activate(frame.objectID);choose([frame.elementID]);canvas?.synchronize();canvas?.revealStoryPage(frame.objectID)
  }
  func exportPublication(_ document:PublicationDocument) {
    canvas?.finishText();guard let store,let project=store.project else{return}
    let report=PublicationOutput.preflight(project,documentID:document.id,assets:assets)
    guard report["can_export"] as? Bool==true else{
      store.error=(report["issues"] as? [[String:Any]] ?? []).filter{$0["severity"] as? String=="error"}.compactMap{$0["message"] as? String}.joined(separator:"\n");return
    }
    let panel=NSSavePanel();panel.allowedContentTypes=[.pdf];panel.nameFieldStringValue=document.name.replacingOccurrences(of:"/",with:"-")+".pdf"
    guard panel.runModal() == .OK,let url=panel.url else{return}
    do {_ = try store.publicationGraphicsCall("form_export_publication",["publication_id":document.id.uuidString,"path":url.path]);store.toast("Publication PDF exported")}
    catch {store.error=error.localizedDescription}
  }
}

private struct PublicationFrameOption:Identifiable {
  let frame:StoryFrameID,name:String,hasText:Bool
  var id:String {frame.objectID.uuidString+"/"+frame.elementID.uuidString}
}

struct PublicationControls:View {
  @ObservedObject var session:ArtworkSession
  @State private var target=""
  @State private var pagesOpen=false
  @State private var preflightOpen=false
  @State private var report:[String:Any]=[:]
  @State private var existingStory=""
  private var story:TextStory? {session.selectedTextStory}
  private var document:PublicationDocument? {session.currentPublication}
  private var frame:StoryFrameID? {
    guard let object=session.object,let element=session.primary,element.kind=="text" else{return nil}
    return .init(objectID:object.id,elementID:element.id)
  }
  private var options:[PublicationFrameOption] {
    (session.store?.project?.objects ?? []).filter{object in object.recipeID=="artboard" && !object.isCanvasWorkspace && !object.locked && object.artworkSourceID==nil && session.store?.project?.objects.filter({$0.designID==object.designID}).count==1}.flatMap{object in
      (object.artwork?.elements ?? []).filter{$0.kind=="text" && $0.storyFrame==nil && object.artwork?.isLocked($0)==false}.map{
        PublicationFrameOption(frame:.init(objectID:object.id,elementID:$0.id),name:object.name+" · "+String($0.title.prefix(32)),hasText:!$0.text.isEmpty)
      }
    }
  }
  private var overset:Int {
    if let editor=session.canvas?.storyEditor {return editor.composition.oversetRange.length}
    guard let story,let context=session.store?.project?.resolvedTextStory(story.id) else{return 0}
    return PublicationStoryLayout.composition(context).oversetRange.length
  }
  private func start() {
    guard let frame else{return}
    let publication=document?.id
    _ = session.publicationEdit("Linked text story") {project in
      _ = try PublicationCommands.createStory(in:&project,frames:[frame],name:session.primary?.title ?? "Text story",publicationID:publication)
    }
  }
  private func link(_ id:UUID,to frame:StoryFrameID) {
    _ = session.publicationEdit("Linked story frame") {project in
      if let documentID=project.textStories?.first(where:{$0.id==id})?.publicationID,
        var document=project.publications?.first(where:{$0.id==documentID}),!document.pages.contains(where:{$0.objectID==frame.objectID}) {
        document.pages.append(.init(objectID:frame.objectID));try PublicationCommands.setPublication(in:&project,document:document)
      }
      try PublicationCommands.appendFrames(in:&project,storyID:id,frames:[frame])
    }
    target=""
  }
  private func createDocument() {
    guard let object=session.object else{return}
    var pages=story?.frames.map(\.objectID) ?? [object.id],seen=Set<UUID>()
    pages=pages.filter{seen.insert($0).inserted}
    _ = session.publicationEdit("Created publication") {project in _ = try PublicationCommands.createPublication(in:&project,name:"Untitled publication",pages:pages)}
  }
  private func settings(_ body:(inout PublicationDocument)->Void) {
    guard var document else{return};body(&document)
    _ = session.publicationEdit("Updated publication") {try PublicationCommands.setPublication(in:&$0,document:document)}
  }
  private func addPage() {
    guard let document else{return};let source=story?.id
    var page:UUID?
    if session.publicationEdit("Added publication page",{project in
      let last=document.pages.last.flatMap{entry in project.objects.first{$0.id==entry.objectID}}
      page=try PublicationCommands.addPage(in:&project,publicationID:document.id,width:last?.artworkSize.x ?? 160,height:last?.artworkSize.y ?? 210,storyID:source,columns:2).0
    }),let page {
      session.activate(page)
      if let first=session.object?.artwork?.elements.first(where:{$0.kind=="text"}) {session.choose([first.id])}
      session.canvas?.synchronize();session.canvas?.revealStoryPage(page)
    }
  }
  var body:some View {
    if let object=session.object,object.recipeID=="artboard",!object.isCanvasWorkspace,object.artworkSourceID==nil,session.store?.project?.objects.filter({$0.designID==object.designID}).count==1 {
      DisclosureGroup("Text flow & publication") {
        VStack(alignment:.leading,spacing:10) {
          if let story {
            Text(story.name).font(.system(size:11,weight:.medium))
            HStack {
              Text("\(story.frames.count) linked frames").foregroundStyle(Palette.secondary)
              Spacer()
              Button("Story source") {session.canvas?.openStorySource(story.id)}
            }
            if overset>0 {
              Button("Overset text: \(overset) source units",systemImage:"plus.app") {session.canvas?.openStorySource(story.id)}.foregroundStyle(Palette.accent)
            }
            if let frame,let index=story.frames.firstIndex(of:frame) {
              HStack {
                Button("Previous") {session.focusStoryFrame(story.frames[index-1])}.disabled(index==0)
                Text("Frame \(index+1) / \(story.frames.count)").foregroundStyle(Palette.secondary)
                Button("Next") {session.focusStoryFrame(story.frames[index+1])}.disabled(index+1==story.frames.count)
              }
              Button("Remove frame from flow") {_ = session.publicationEdit("Unlinked story frame") {try PublicationCommands.unlinkFrames(in:&$0,frames:[frame])}}
                .help("Removes this frame's capacity. All source words stay in the story, including when no frames remain.")
            }
            if !options.isEmpty {
              Picker("Link another frame",selection:$target) {
                Text("Choose a text frame").tag("")
                ForEach(options) {Text($0.name).tag($0.id)}
              }
              if let selected=options.first(where:{$0.id==target}) {
                Button(selected.hasText ? "Link + append its words":"Link empty frame") {link(story.id,to:selected.frame)}
              }
            }
          } else if frame != nil {
            Button("Start linked text story",systemImage:"text.badge.plus") {start()}
            if let project=session.store?.project,!(project.textStories ?? []).isEmpty {
              Picker("Existing story",selection:$existingStory) {
                Text("Choose story").tag("")
                ForEach(project.textStories ?? []) {Text($0.name).tag($0.id.uuidString)}
              }
              if let id=UUID(uuidString:existingStory),let frame {Button("Append this frame") {link(id,to:frame)}}
            }
          }
          Divider()
          if let document {
            PublicationCommittedField(title:"Publication name",value:document.name,allowsEmpty:false) {name in settings{$0.name=name}}
            HStack {
              Button("\(document.pages.count) pages…") {pagesOpen=true}.accessibilityLabel("Publication pages")
              Spacer()
              Button("Add page",systemImage:"plus") {addPage()}.accessibilityLabel("Add publication page")
            }
            PublicationCommittedField(title:"Default language (BCP 47)",value:document.language ?? "",allowsEmpty:true) {value in settings{$0.language=value.isEmpty ? nil:value}}
              .help("Inherited by linked stories without their own language override.")
            Toggle("Baseline grid",isOn:Binding(get:{document.baselineGrid != nil},set:{enabled in settings{$0.baselineGrid=enabled ? .init():nil}})).toggleStyle(.checkbox)
            if let grid=document.baselineGrid {
              ScalarArtworkField("Grid spacing",value:grid.spacing,unit:"pt") {value in settings{$0.baselineGrid?.spacing=min(200,max(4,value))}}
              ScalarArtworkField("Grid origin",value:grid.origin,unit:"pt") {value in settings{$0.baselineGrid?.origin=value}}
              if story != nil {
                Toggle("Align paragraphs to grid",isOn:Binding(get:{session.inspectedTypography.alignToBaselineGrid==true},set:{enabled in session.typography{$0.alignToBaselineGrid=enabled}})).toggleStyle(.checkbox)
                  .help("Applies to selected paragraphs while editing, or the selected story otherwise.")
              }
            }
            if let project=session.store?.project,document.pages.contains(where:{page in project.objects.first(where:{$0.id==page.objectID}).flatMap{project.surfaceArtwork($0)}?.requiresInkOutput==true}) {
              ProductionInkExportControls(session:session,publicationID:document.id)
            } else {
            HStack {
              Button("Preflight") {
                if let project=session.store?.project {report=PublicationOutput.preflight(project,documentID:document.id,assets:session.assets);preflightOpen=true}
              }.accessibilityLabel("Publication preflight")
              Spacer()
              Button("Export booklet PDF…") {session.exportPublication(document)}.accessibilityLabel("Export booklet PDF")
            }
            }
          } else {Button("Create publication",systemImage:"book.closed") {createDocument()}}
        }.buttonStyle(.borderless).font(.system(size:10)).padding(.top,8)
      }
      .popover(isPresented:$pagesOpen) {pageEditor.padding(18).frame(width:330)}
      .popover(isPresented:$preflightOpen) {preflight.padding(18).frame(width:360)}
    }
  }
  @ViewBuilder private var pageEditor:some View {
    if let document {
      VStack(alignment:.leading,spacing:12) {
        SectionLabel("PUBLICATION PAGES")
        ForEach(Array(document.pages.enumerated()),id:\.element.id) {index,page in
          HStack {
            Text("\(index+1)").monospacedDigit().foregroundStyle(Palette.secondary)
            Text(session.store?.project?.objects.first{$0.id==page.objectID}?.name ?? "Missing page").lineLimit(1)
            Spacer()
            Button {settings{$0.pages.swapAt(index,index-1)}} label:{Image(systemName:"arrow.up")}.accessibilityLabel("Move page \(index+1) earlier").disabled(index==0)
            Button {settings{$0.pages.swapAt(index,index+1)}} label:{Image(systemName:"arrow.down")}.accessibilityLabel("Move page \(index+1) later").disabled(index+1==document.pages.count)
            Button {session.activate(page.objectID);session.canvas?.revealStoryPage(page.objectID)} label:{Image(systemName:"arrow.up.right.square")}.accessibilityLabel("Open page \(index+1)")
          }
        }
        Divider()
        ScalarArtworkField("Top margin",value:document.margins.top,unit:"mm") {value in settings{$0.margins.top=max(0,value)}}
        ScalarArtworkField("Bottom margin",value:document.margins.bottom,unit:"mm") {value in settings{$0.margins.bottom=max(0,value)}}
        ScalarArtworkField("Left margin",value:document.margins.left,unit:"mm") {value in settings{$0.margins.left=max(0,value)}}
        ScalarArtworkField("Right margin",value:document.margins.right,unit:"mm") {value in settings{$0.margins.right=max(0,value)}}
        Text("Margins apply when adding new body frames. Page order also updates linked-story reading order.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      }.font(.system(size:11))
    }
  }
  private var preflight:some View {
    VStack(alignment:.leading,spacing:12) {
      SectionLabel("PUBLICATION PREFLIGHT")
      Text(report["can_export"] as? Bool==true ? "Ready to export":"Review before export").font(.system(size:14,weight:.medium))
      ForEach(Array((report["issues"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) {_,item in
        Text(item["message"] as? String ?? "").font(.system(size:11)).foregroundStyle(item["severity"] as? String=="error" ? Palette.accent:Palette.secondary)
      }
      if (report["issues"] as? [[String:Any]] ?? []).isEmpty {Text("Linked stories fit their physical pages.").font(.system(size:11)).foregroundStyle(Palette.secondary)}
    }
  }
}

private struct PublicationCommittedField:View {
  let title:String,value:String,allowsEmpty:Bool
  let onCommit:(String)->Void
  @State private var draft=""
  @State private var lastCommitted=""
  @FocusState private var focused:Bool
  private func commit() {
    guard draft != lastCommitted else{return}
    let text=draft.trimmingCharacters(in:.whitespacesAndNewlines)
    if (allowsEmpty || !text.isEmpty),text.count<=500,text != value {onCommit(text)}
    draft = (!allowsEmpty && text.isEmpty) || text.count>500 ? value:text
    lastCommitted=draft
  }
  var body:some View {
    TextField(title,text:$draft).focused($focused).onSubmit{commit()}
      .onAppear{draft=value;lastCommitted=value}
      .onChange(of:value) {_,value in if !focused || draft==lastCommitted {draft=value;lastCommitted=value}}
      .onChange(of:focused) {_,focused in if !focused {commit()}}
      .onReceive(NotificationCenter.default.publisher(for:.formCommitArtworkFields)) {_ in commit()}
  }
}
