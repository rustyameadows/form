import FormCore
import SwiftUI

struct ParagraphListControls:View {
  @ObservedObject var session:ArtworkSession
  @State private var start=1.0
  private var item:ParagraphListItem? {
    let e=session.primary
    let ranges=ParagraphLists.selectedParagraphs(in:e?.text ?? "",range:session.editingText ? session.characterRange:nil)
    return ranges.lazy.compactMap{range in e?.listItems?.first{$0.location==range.location}}.first
  }
  private var previous:ParagraphListItem? {
    guard let e=session.primary,let index=session.art.elements.firstIndex(where:{$0.id==e.id}) else{return nil}
    return session.art.elements.prefix(index).reversed().lazy.flatMap{($0.listItems ?? []).reversed()}.first{$0.marker == .decimal}
  }
  var body:some View {
    VStack(alignment:.leading,spacing:8) {
      Text("Paragraph lists").foregroundStyle(Palette.secondary)
      HStack {
        Button("Bullets",systemImage:"list.bullet") {session.paragraphList(["marker":"bullet"])}
        Button("Numbers",systemImage:"list.number") {session.paragraphList(["marker":"decimal"])}
        Button("Remove") {session.paragraphList(["list_action":"remove"])}.disabled(item==nil)
      }.buttonStyle(.borderless)
      if let item {
        HStack {
          Button("Outdent",systemImage:"decrease.indent") {session.paragraphList(["list_action":"outdent"])}.disabled(item.level==0)
          Button("Indent",systemImage:"increase.indent") {session.paragraphList(["list_action":"indent"])}.disabled(item.level==5)
          Text("Level \(item.level+1)").foregroundStyle(Palette.secondary)
        }.buttonStyle(.borderless)
        if item.marker == .decimal {
          HStack {
            TextField("Start at",value:$start,format:.number.precision(.fractionLength(0))).frame(width:55)
            Button("Restart") {session.paragraphList(["list_action":"restart","restart":Int(min(999999,max(1,start.rounded())))])}
            Button("Continue previous") {
              if let previous {session.paragraphList(["list_action":"continue","list_id":previous.listID.uuidString])}
            }.disabled(previous==nil)
          }.buttonStyle(.borderless)
        }
      }
    }.help("Return creates a list item; Return on an empty item exits. Tab indents, Shift-Tab outdents. Numbers continue across text objects sharing the same list identity, in layer order.")
  }
}
