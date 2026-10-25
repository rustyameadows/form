import FormCore
import SwiftUI

private struct TabDraft: Identifiable {
  var id=UUID(),position:String,alignment:String,separator:String
  var defaultSeparator:Bool
  init(_ stop:TextTabStop) {
    position=String(stop.location);alignment=stop.alignment;separator=stop.decimalSeparator ?? "."
    defaultSeparator=stop.decimalSeparator == nil
  }
}

struct ParagraphTabsPanel: View {
  @ObservedObject var session: ArtworkSession
  @Environment(\.dismiss) private var dismiss
  @State private var custom=false
  @State private var systemStops=true
  @State private var tabs:[TabDraft]=[]
  @State private var interval="0"
  @State private var error=""
  @State private var projectID:UUID?
  @State private var objectID:UUID?
  @State private var selected=Set<UUID>()
  @State private var textRange:NSRange?
  private func apply() {
    do {
      var values:[TextTabStop]=[]
      var repeatInterval:Double?
      if custom {
        guard let value=Double(interval),value.isFinite else { throw FormError.invalid("Use a numeric repeating interval in points.") }
        repeatInterval=session.inspectedTypography.defaultTabInterval == nil && value == 0 ? nil : value
        values=try tabs.map { draft in
          guard let value=Double(draft.position),value.isFinite else { throw FormError.invalid("Use numeric tab positions in points.") }
          return TextTabStop(location:value,alignment:draft.alignment,
            decimalSeparator:draft.alignment == "decimal" && !(draft.defaultSeparator && draft.separator == ".") ? draft.separator : nil)
        }.sorted { $0.location < $1.location }
      }
      var type=session.inspectedTypography
      type.tabStops=custom && !systemStops ? values : nil;type.defaultTabInterval=repeatInterval
      try validateTypography(type)
      guard let store=session.store,let objectID,store.project?.id==projectID,session.objectID==objectID,session.selection==selected else {
        throw FormError.invalid("The text selection changed. Close and reopen Tab stops for the new selection.")
      }
      if session.editingText {
        session.typography { $0.tabStops=type.tabStops;$0.defaultTabInterval=type.defaultTabInterval }
      } else {
        var patch:[String:Any]=["tabStops":NSNull(),"defaultTabInterval":NSNull()]
        if let stops=type.tabStops { patch["tabStops"]=try jsonObject(stops) }
        if let interval=type.defaultTabInterval { patch["defaultTabInterval"]=interval }
        var args:[String:Any]=["command":"paragraph","object_id":objectID.uuidString,
          "element_ids":selected.map(\.uuidString),"typography":patch]
        if let textRange { args["location"]=textRange.location;args["length"]=textRange.length }
        try store.engine.call("form_edit_artwork",arguments:args,source:"Studio");store.changed()
      }
      dismiss()
    } catch { self.error=error.localizedDescription }
  }
  var body: some View {
    VStack(alignment:.leading,spacing:15) {
      HStack { SectionLabel("PARAGRAPH TAB STOPS");Spacer();Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
      Text("Align columns without adding spaces.").font(.system(size:18,weight:.medium))
      Text(textRange != nil ? "Applies to the selected paragraphs and keeps character formatting." : "Applies to the selected text objects.")
        .font(.system(size:11)).foregroundStyle(Palette.secondary)
      Toggle("Custom tab stops",isOn:$custom).toggleStyle(.checkbox)
      if custom {
        Toggle("Use system tab stops",isOn:$systemStops).toggleStyle(.checkbox)
        if !systemStops {
        ScrollView {
          VStack(spacing:10) {
            ForEach($tabs) { $tab in
              HStack(spacing:8) {
                TextField("Position",text:$tab.position).textFieldStyle(.roundedBorder).frame(width:75)
                Text("pt").font(.system(size:10)).foregroundStyle(Palette.secondary)
                Picker("Alignment",selection:$tab.alignment) {
                  Text("Left").tag("left");Text("Center").tag("center");Text("Right").tag("right");Text("Decimal").tag("decimal")
                }.labelsHidden().frame(width:115)
                if tab.alignment == "decimal" {
                  Picker("Decimal separator",selection:$tab.separator) { Text("Period").tag(".");Text("Comma").tag(",") }
                    .labelsHidden().frame(width:85)
                }
                Spacer(minLength:0)
                Button { tabs.removeAll { $0.id == tab.id } } label: { Image(systemName:"minus.circle") }.buttonStyle(.plain).help("Remove tab stop")
              }
            }
          }.padding(.vertical,5)
        }.frame(minHeight:80,maxHeight:260)
        }
        HStack {
          Button("Add tab") {
            systemStops=false
            let next=(tabs.compactMap { Double($0.position) }.max() ?? 0)+28
            tabs.append(.init(.init(location:min(10000,next))))
          }.disabled(tabs.count>=64)
          Spacer()
          Text("Repeat every").font(.system(size:11))
          TextField("Repeating interval",text:$interval).textFieldStyle(.roundedBorder).frame(width:65)
          Text("pt").font(.system(size:10))
        }
        Text("Positions are in typographic points. Zero repeat stops automatic tabs after the last explicit stop.")
          .font(.system(size:10)).foregroundStyle(Palette.secondary)
      } else {
        Text("System defaults: twelve left tabs at 28-point intervals.")
          .font(.system(size:11)).foregroundStyle(Palette.secondary).padding(.vertical,10)
      }
      if !error.isEmpty { Text(error).font(.system(size:11)).foregroundStyle(Palette.accent) }
      HStack { Button("System defaults") { custom=false;systemStops=true;tabs=[];interval="0" };Spacer();Button("Apply") { apply() }.buttonStyle(.borderedProminent).tint(Palette.ink) }
    }.padding(22).frame(width:470).background(Palette.paper)
      .onAppear {
        let type=session.inspectedTypography
        projectID=session.store?.project?.id;objectID=session.objectID;selected=session.selection
        textRange=session.editingText ? session.characterRange : nil
        custom=type.usesCustomTabs;systemStops=type.tabStops == nil;tabs=(type.tabStops ?? []).map(TabDraft.init)
        interval=String(type.defaultTabInterval ?? 0)
      }
  }
}
