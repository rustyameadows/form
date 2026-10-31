import AppKit
import FormCore
import FormGraphics
import SwiftUI

struct DocumentFontsPanel:View {
  @ObservedObject var session:ArtworkSession
  @Environment(\.dismiss) private var dismiss
  @State private var from=""
  @State private var to=""
  @State private var choosing=false
  @State private var showAll=false
  @State private var report:[String:Any]?
  @State private var context:FontDocumentContext
  init(session:ArtworkSession) {
    self.session=session;_context=State(initialValue:FontDocumentContext(store:session.store))
  }
  private var currentProject:Bool {context.matches(session.store)}
  private var usage:[[String:Any]] {session.store?.project.map{FontLibraryCatalog.usage($0)} ?? []}
  private var missing:Int {usage.filter{$0["available"] as? Bool==false}.count}
  private var selected:[[String:Any]] {usage.filter{$0["font_name"] as? String==from}}
  private func review() {
    guard let store=session.store else{return}
    do {report=try store.replaceDocumentFont(from:from,to:to,context:context,dryRun:true) as? [String:Any]}
    catch {store.error=error.localizedDescription}
  }
  private func replace() {
    guard let store=session.store else{return}
    do {
      report=try store.replaceDocumentFont(from:from,to:to,context:context,dryRun:false) as? [String:Any]
    }catch {store.error=error.localizedDescription}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:15) {
      HStack {Text("Document fonts").font(.system(size: 22, weight: .semibold));Spacer();AppCloseButton("Close", keyEquivalent: "\u{1b}"){dismiss()}}
      if !currentProject {Text("The project changed. Close and reopen Document fonts for the current project.").font(.system(size:11)).foregroundStyle(Palette.secondary)}
      ScrollView {
      VStack(alignment:.leading,spacing:15) {
      Text("\(usage.count) assigned faces · \(missing) missing").font(.system(size:11)).foregroundStyle(missing>0 ? Palette.accent:Palette.secondary)
      Text("Assignments remain stored when a face is unavailable. Preview fallback does not change your document.").font(.system(size:11)).foregroundStyle(Palette.secondary)
      ScrollView {
        LazyVStack(alignment:.leading,spacing:7) {
          ForEach(usage,id:\.fontNameIdentity) {entry in
            let name=entry["font_name"] as? String ?? "",available=entry["available"] as? Bool ?? false
            Button {from=name;to="";report=nil} label:{
              HStack {
                VStack(alignment:.leading,spacing:4) {
                  Text(name).font(.system(size:11,weight:.medium))
                  Text("\(entry["assignment_count"] as? Int ?? 0) assignments · \(available ? "Available":"Missing face")").font(.system(size:10)).foregroundStyle(available ? Palette.secondary:Palette.accent)
                }
                Spacer()
                if from==name {Image(systemName:"checkmark.circle.fill").foregroundStyle(Palette.accent)}
              }.padding(10).frame(maxWidth:.infinity).background(from==name ? Palette.accent.opacity(0.08):.white.opacity(0.6),in:RoundedRectangle(cornerRadius:6))
            }.buttonStyle(.plain)
          }
        }
      }.frame(maxHeight:210)
      if let entry=selected.first {
        ForEach(entry["settings_warnings"] as? [String] ?? [],id:\.self) {Text($0).font(.system(size:10)).foregroundStyle(Palette.accent)}
        Divider()
        Text("Replace \(from)").font(.system(size:12,weight:.medium))
        DisclosureGroup("Assignment locations",isExpanded:$showAll) {
          ScrollView {
            VStack(alignment:.leading,spacing:4) {
              ForEach(Array((entry["uses"] as? [[String:Any]] ?? []).enumerated()),id:\.offset) {_,use in
                Text((use["owner"] as? String ?? "")+" · "+(use["kind"] as? String ?? "").replacingOccurrences(of:"_",with:" ")).font(.system(size:10)).foregroundStyle(Palette.secondary)
              }
            }.frame(maxWidth:.infinity,alignment:.leading)
          }.frame(maxHeight:100)
        }.font(.system(size:10))
        HStack {
          Button(to.isEmpty ? "Choose installed replacement…":to) {choosing=true}
            .popover(isPresented:$choosing) {FontBrowser(session:session,onChoose:{name in
              guard context.matches(session.store) else{choosing=false;return}
              to=name;report=nil;choosing=false
            })}
          Spacer()
          Button("Review") {review()}.disabled(to.isEmpty || from==to)
        }
        if let report {
          Text("\(report["replaced_assignments"] as? Int ?? 0) face assignments change. Words, features, axes and rich ranges stay editable.").font(.system(size:11)).foregroundStyle(Palette.secondary)
          ForEach(report["warnings"] as? [String] ?? [],id:\.self) {Text($0).font(.system(size:10)).foregroundStyle(Palette.accent)}
          Button("Replace throughout document") {replace()}.disabled((report["replaced_assignments"] as? Int ?? 0)==0)
        }
      }
      }.frame(maxWidth:.infinity,alignment:.leading).disabled(!currentProject)
      }
    }.padding(24).frame(width:570,height:610).background(Palette.paper)
  }
}

private extension Dictionary where Key==String,Value==Any {
  var fontNameIdentity:String {self["font_name"] as? String ?? ""}
}
