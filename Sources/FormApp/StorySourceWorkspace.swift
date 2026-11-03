import AppKit
import FormCore
import SwiftUI

/// Window chrome around the controller's existing shared native text view.
/// Notes are nonprinting metadata, never inserted into the story's characters.
struct StorySourceWorkspace:View {
  @ObservedObject var editor:PublicationEditingController
  @State private var notesOpen=false
  @State private var editingNoteID:UUID?
  @State private var noteKind:StoryAnnotation.Kind = .note
  @State private var noteBody=""
  private var canSaveNote:Bool {
    !noteBody.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
      && noteBody.utf8.count<=StoryAnnotations.maximumBodyBytes
  }
  var body:some View {
    VStack(spacing:0) {
      toolbar
      InspectorDivider().padding(.horizontal,12)
      if let issue=editor.sourceError,!issue.isEmpty {
        Label(issue,systemImage:"exclamationmark.triangle")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)
          .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,14).padding(.vertical,6)
          .accessibilityIdentifier("story-source-error")
      }
      HStack(spacing:0) {
        StorySourceNativeTextHost(scroll:editor.sourceScrollView)
          .frame(maxWidth:.infinity,maxHeight:.infinity)
        if notesOpen {
          Rectangle().fill(Palette.line).frame(width:1).accessibilityHidden(true)
          notes.frame(width:248)
        }
      }.frame(maxWidth:.infinity,maxHeight:.infinity)
      InspectorDivider().padding(.horizontal,12)
      footer
    }
    .background(Palette.paper)
    .frame(minWidth:520,minHeight:320)
    .onChange(of:editor.selectedSourceAnnotationID){_,id in
      if let note=editor.sourceNotes.first(where:{$0.id==id}) {edit(note)}
    }
    .onChange(of:editor.sourceRevision){_,_ in
      if let id=editingNoteID,!editor.sourceNotes.contains(where:{$0.id==id}) {newNote()}
    }
  }
  private var toolbar:some View {
    HStack(spacing:3) {
      formatButton(.bold,title:"Bold",symbol:"bold",shortcut:"⌘B")
      formatButton(.italic,title:"Italic",symbol:"italic",shortcut:"⌘I")
      formatButton(.underline,title:"Underline",symbol:"underline",shortcut:"⌘U")
      Rectangle().fill(Palette.line).frame(width:1,height:18).padding(.horizontal,7).accessibilityHidden(true)
      if editor.sourceFrameOptions.isEmpty {
        Text("No linked frames").font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
      }else {
        Picker("Linked page and frame",selection:Binding<StoryFrameID?>(get:{editor.sourceSelectedFrame},set:{frame in
          if let frame {editor.navigateSourceFrame(frame)}
        })) {
          if editor.sourceSelectedFrame==nil {Text("Choose frame").tag(Optional<StoryFrameID>.none)}
          ForEach(editor.sourceFrameOptions){option in Text(option.label).tag(Optional(option.id))}
        }.labelsHidden().pickerStyle(.menu).font(InspectorStyle.labelFont)
          .frame(minWidth:100,maxWidth:220).accessibilityIdentifier("story-source-frame")
      }
      WorkspaceToolbarButton("Show on Canvas",symbol:"arrow.up.left.square",showsTitle:true,identifier:"story-source-show-canvas"){
        editor.showSourceOnCanvas()
      }.disabled(editor.sourceFrameOptions.isEmpty)
      Spacer(minLength:4)
      WorkspaceToolbarButton("Find in story",symbol:"magnifyingglass",help:"Find in story · ⌘F",identifier:"story-source-find"){editor.findInSource()}
      WorkspaceToolbarButton("Notes & references",symbol:"note.text",isSelected:notesOpen,
        help:"Nonprinting notes and references",identifier:"story-source-toggle-notes"){notesOpen.toggle()}
    }.padding(.horizontal,8).frame(height:FloatingPanelStyle.headerHeight)
  }
  private func formatButton(_ format:StorySourceFormat,title:String,symbol:String,shortcut:String)->some View {
    let state=editor.formatState(format)
    return WorkspaceToolbarButton(title,symbol:symbol,isSelected:state.isOn || state.isMixed,
      help:title+" · "+shortcut,value:state.isMixed ? "Mixed":state.isOn ? "On":"Off",
      identifier:"story-source-format-"+title.lowercased()) {editor.toggleSourceFormat(format)}
      .disabled(!state.available)
      .overlay(alignment:.bottom){
        if state.isMixed {Rectangle().fill(Palette.secondary).frame(width:8,height:1).padding(.bottom,3).allowsHitTesting(false)}
      }
  }
  private var footer:some View {
    HStack(spacing:12) {
      Text("\(editor.sourceWordCount.formatted()) words")
        .accessibilityIdentifier("story-source-word-count")
      Text("\(editor.sourceCharacterCount.formatted()) characters").foregroundStyle(Palette.secondary)
      Spacer(minLength:4)
      if editor.sourceOverflowCount>0 {
        Button {editor.goToSourceOverflow()} label:{
          Label("\(editor.sourceOverflowCount.formatted()) overset",systemImage:"plus.app")
        }.buttonStyle(.borderless).foregroundStyle(Palette.accent)
          .help("Go to the text that does not fit its linked frames")
          .accessibilityIdentifier("story-source-go-overflow")
      }else {
        Label("Text fits",systemImage:"checkmark.circle").foregroundStyle(Palette.secondary)
          .accessibilityIdentifier("story-source-fit-status")
      }
      Menu {
        ForEach([0.75,1.0,1.25,1.5,2.0],id:\.self){zoom in
          Button("\(Int(zoom*100))%") {editor.setSourceZoom(zoom)}
        }
      }label:{
        Text("\(Int((editor.sourceZoom*100).rounded()))%")
          .font(InspectorStyle.valueFont).frame(minWidth:38)
      }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Story source zoom")
        .accessibilityIdentifier("story-source-zoom")
    }.font(InspectorStyle.captionFont).padding(.horizontal,14).frame(height:32)
  }
  private var notes:some View {
    VStack(alignment:.leading,spacing:10) {
      HStack {
        Text("Notes & references").font(.system(size:11,weight:.semibold))
        Spacer(minLength:0)
        WorkspaceToolbarButton("New note",symbol:"plus",identifier:"story-source-new-note"){newNote()}
      }
      Text("Notes and references stay off the printed page.")
        .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
      ScrollView {
        LazyVStack(spacing:3) {
          ForEach(editor.sourceNotes){note in
            WorkspaceNavigationRow(title:note.body.replacingOccurrences(of:"\n",with:" "),
              subtitle:annotationSubtitle(note),symbol:note.kind == .reference ? "link":"note.text",
              selected:editingNoteID==note.id,accessibilityLabel:(note.kind == .reference ? "Reference: ":"Note: ")+note.body,
              identifier:"story-source-note-"+note.id.uuidString){
              editor.selectSourceAnnotation(note.id);edit(note)
            }
          }
          if editor.sourceNotes.isEmpty {
            Text("Select source text, then add a note or reference. An insertion point can hold a note too.")
              .font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
              .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,10)
          }
        }
      }.frame(maxWidth:.infinity,maxHeight:.infinity)
      InspectorDivider()
      Text(editingNoteID==nil ? "New annotation":"Edit annotation")
        .font(InspectorStyle.headingFont).foregroundStyle(Palette.secondary)
      Picker("Annotation kind",selection:$noteKind) {
        Text("Note").tag(StoryAnnotation.Kind.note);Text("Reference").tag(StoryAnnotation.Kind.reference)
      }.labelsHidden().pickerStyle(.segmented).accessibilityIdentifier("story-source-note-kind")
      TextEditor(text:$noteBody).font(InspectorStyle.labelFont).scrollContentBackground(.hidden)
        .padding(6).frame(height:100).background(Palette.surface,in:RoundedRectangle(cornerRadius:InspectorStyle.controlRadius))
        .overlay{RoundedRectangle(cornerRadius:InspectorStyle.controlRadius).strokeBorder(Palette.line,lineWidth:0.75).allowsHitTesting(false)}
        .accessibilityLabel("Note or reference text").accessibilityIdentifier("story-source-note-body")
      if noteBody.utf8.count>StoryAnnotations.maximumBodyBytes {
        Text("Use at most \(StoryAnnotations.maximumBodyBytes.formatted()) UTF-8 bytes.")
          .font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)
      }
      HStack {
        if let id=editingNoteID {
          Button("Remove",role:.destructive){editor.removeSourceAnnotation(id);newNote()}
            .buttonStyle(.borderless).accessibilityIdentifier("story-source-remove-note")
        }
        Spacer(minLength:0)
        Button(editingNoteID==nil ? "Add":"Save"){
          if editor.saveSourceAnnotation(id:editingNoteID,kind:noteKind,body:noteBody),
            let selected=editor.selectedSourceAnnotationID,let note=editor.sourceNotes.first(where:{$0.id==selected}) {edit(note)}
        }.buttonStyle(InspectorActionStyle()).disabled(!canSaveNote).accessibilityIdentifier("story-source-save-note")
      }
    }.padding(12).background(Palette.paper)
  }
  private func edit(_ note:StoryAnnotation){editingNoteID=note.id;noteKind=note.kind;noteBody=note.body}
  private func newNote(){editingNoteID=nil;noteKind = .note;noteBody=""}
  private func annotationSubtitle(_ note:StoryAnnotation)->String {
    let kind=note.kind == .reference ? "Reference":"Note"
    guard let story=editor.sourceStory,
      StoryAnnotations.validRange(.init(location:note.location,length:note.length),in:story.text) else{return kind}
    if note.length==0 {return kind+" · Insertion point"}
    let excerpt=(story.text as NSString).substring(with:.init(location:note.location,length:note.length))
      .replacingOccurrences(of:"\n",with:" ")
    return kind+" · "+String(excerpt.prefix(40))
  }
}

/// Reparents the exact scroll view owned by the editing controller. The SwiftUI
/// shell never constructs another NSTextView, text storage or layout manager.
struct StorySourceNativeTextHost:NSViewRepresentable {
  let scroll:NSScrollView?
  func makeNSView(context:Context)->StorySourceTextHostView {StorySourceTextHostView()}
  func updateNSView(_ view:StorySourceTextHostView,context:Context){view.install(scroll)}
  static func dismantleNSView(_ view:StorySourceTextHostView,coordinator:()){view.install(nil)}
}
final class StorySourceTextHostView:NSView {
  private weak var scroll:NSScrollView?
  func install(_ incoming:NSScrollView?) {
    guard scroll !== incoming else{return}
    scroll?.removeFromSuperview();scroll=incoming
    if let incoming {
      incoming.removeFromSuperview();incoming.autoresizingMask=[.width,.height]
      incoming.frame=bounds;addSubview(incoming)
      incoming.setAccessibilityIdentifier("story-source-scroll")
    }
    needsLayout=true
  }
  override func layout(){super.layout();scroll?.frame=bounds}
}
