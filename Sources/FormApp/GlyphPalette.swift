import AppKit
import CoreText
import FormCore
import FormGraphics
import SwiftUI

struct GlyphPalette: View {
  @ObservedObject var session: ArtworkSession
  @Environment(\.dismiss) private var dismiss
  @State private var projectID: UUID?
  @State private var objectID: UUID?
  @State private var element: ArtworkElement?
  @State private var sourceRange: NSRange?
  @State private var type=Typography()
  @State private var fontName=""
  @State private var nominalPoints=48.0
  @State private var mode="alternates"
  @State private var query=""
  @State private var offset=0
  @State private var total=0
  @State private var options:[GlyphOption]=[]
  @State private var error=""
  @State private var loading=false
  private let pageSize=48
  private var gridHeight: CGFloat {
    mode=="all" ? 310 : CGFloat(min(240,max(90,Int(ceil(Double(options.count)/6))*77+4)))
  }
  private var selectedGlyph: FontGlyph? {
    guard let sourceRange else { return nil }
    return element?.glyphOverrides?.first { NSIntersectionRange($0.range,sourceRange).length>0 }?.glyph
  }
  private func capture() {
    guard session.elements.count==1,let e=session.primary,e.kind=="text" else {
      error="Select one text object to browse its glyphs.";return
    }
    projectID=session.store?.project?.id;objectID=session.objectID;element=e
    type=session.inspectedTypography;fontName=type.fontName;nominalPoints=session.inspectedSize
    if session.editingText,session.characterRange.length>0 {sourceRange=session.characterRange}
    else if e.text.count==1 {sourceRange=NSRange(location:0,length:e.text.utf16.count)}
    if sourceRange==nil {mode="all"}
  }
  private func refresh() {
    guard let e=element,!fontName.isEmpty else { return }
    do {
      error=""
      if mode=="alternates" {
        guard let range=sourceRange else {options=[];total=0;return}
        options=try GlyphCatalog.alternates(fontName:fontName,text:e.text,range:range,typography:type,pointSize:nominalPoints)
        total=options.count
      } else {
        let page=try GlyphCatalog.page(fontName:fontName,query:query,offset:offset,limit:pageSize)
        options=page.options;total=page.total
      }
    } catch {options=[];total=0;self.error=error.localizedDescription}
  }
  private func apply(_ glyph: FontGlyph?) {
    do {
      guard let store=session.store,let objectID,let e=element,let range=sourceRange,
        store.project?.id==projectID,session.objectID==objectID,session.selection==[e.id],
        let current=session.art.elements.first(where:{$0.id==e.id}),
        (current.text as NSString).isEqual(to:e.text),!session.art.isLocked(current),
        let object=session.object,store.project?.artworkOwner(object).locked==false else {
        throw FormError.invalid("The text selection changed. Close and reopen Glyphs for the new selection.")
      }
      if try session.canvas?.applyGlyph(glyph,sourceRange:range) != true {
        try store.engine.call("form_edit_artwork",arguments:["command":"glyph","object_id":objectID.uuidString,
          "element_ids":[e.id.uuidString],"location":range.location,"length":range.length,
          "glyph":try glyph.map {try jsonObject($0)} ?? NSNull()],source:"Studio")
        store.changed()
        session.canvas?.window?.makeFirstResponder(session.canvas)
      }
      dismiss()
    } catch {self.error=error.localizedDescription}
  }
  var body: some View {
    VStack(alignment:.leading,spacing:15) {
      HStack {
        SectionLabel("GLYPHS");Spacer()
        Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)
      }
      Text(NSFont(name:fontName,size:12)?.displayName ?? fontName)
        .font(.system(size:20,weight:.medium)).lineLimit(1)
      if let e=element,let range=sourceRange,range.location>=0,NSMaxRange(range)<=e.text.utf16.count {
        HStack(spacing:8) {
          Text("Source").foregroundStyle(Palette.secondary)
          Text((e.text as NSString).substring(with:range)).font(.system(size:12,design:.monospaced)).lineLimit(1)
          Spacer()
          if let selectedGlyph {Text(selectedGlyph.glyphName ?? "Glyph \(selectedGlyph.glyphID)").foregroundStyle(Palette.secondary).lineLimit(1)}
        }.font(.system(size:11))
      } else {
        Text("Select a character or cluster on the canvas to apply a glyph. You can browse the font here.")
          .font(.system(size:11)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
      }
      Picker("Glyph view",selection:$mode) {
        Text("Alternates for selection").tag("alternates")
        Text("All glyphs").tag("all")
      }.pickerStyle(.segmented).labelsHidden()
      if mode=="all" {
        TextField("Search glyph name, ID, or U+code",text:$query).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Search glyphs")
      }
      ScrollView {
        if loading {ProgressView().frame(maxWidth:.infinity,minHeight:80)}
        else if options.isEmpty {
          Text(mode=="alternates" ? "No single-glyph alternatives for this selection. Try All glyphs or select a complete character or ligature."
            : "No glyphs match this search.")
            .font(.system(size:12)).foregroundStyle(Palette.secondary).padding(22)
        } else {
          LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:6),spacing:8) {
            ForEach(options) { option in
              let selected=selectedGlyph.map{$0.fontName==option.glyph.fontName && $0.glyphID==option.glyph.glyphID} ?? option.current
              Button {apply(option.glyph)} label: {
                VStack(spacing:3) {
                  NativeGlyphPreview(glyph:option.glyph,type:type,nominalPoints:nominalPoints).frame(height:42)
                  Text(option.glyph.glyphName ?? "#\(option.glyph.glyphID)")
                    .font(.system(size:9)).lineLimit(1).truncationMode(.middle)
                }.padding(.vertical,7).frame(maxWidth:.infinity)
                  .foregroundStyle(Palette.ink)
                  .background(selected ? Palette.accent.opacity(0.10) : Color.white.opacity(0.65),in:RoundedRectangle(cornerRadius:8))
                  .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(selected ? Palette.accent : Palette.line,lineWidth:selected ? 1.5:1))
              }.buttonStyle(.plain).disabled(sourceRange==nil)
                .help("\(option.label) · Glyph \(option.glyph.glyphID)")
                .accessibilityLabel("Apply \(option.glyph.glyphName ?? option.label), glyph \(option.glyph.glyphID)")
                .accessibilityValue(selected ? "Current":"")
            }
          }.padding(2)
        }
      }.frame(height:gridHeight)
      if mode=="all" {
        HStack {
          Button {offset=max(0,offset-pageSize)} label:{Image(systemName:"chevron.left")}.disabled(offset==0).accessibilityLabel("Previous glyph page")
          Text(total==0 ? "0 glyphs":"\(min(offset+1,total))–\(min(offset+pageSize,total)) of \(total)")
            .font(.system(size:10,design:.monospaced)).foregroundStyle(Palette.secondary)
          Button {offset+=pageSize} label:{Image(systemName:"chevron.right")}.disabled(offset+pageSize>=total).accessibilityLabel("Next glyph page")
          Spacer()
        }.buttonStyle(.borderless)
      }
      if !error.isEmpty {Text(error).font(.system(size:11)).foregroundStyle(Palette.accent).fixedSize(horizontal:false,vertical:true)}
      Divider()
      HStack {
        Text("Source text stays editable.").font(.system(size:10)).foregroundStyle(Palette.secondary)
        Spacer()
        Button("Use font shaping") {apply(nil)}.disabled(sourceRange==nil || selectedGlyph==nil).font(.system(size:11))
      }
    }.padding(22).frame(width:480).background(Palette.paper)
      .onAppear {capture()}
      .onChange(of:mode) {_,_ in offset=0}
      .onChange(of:query) {_,_ in offset=0}
      .task(id:"\(fontName)|\(mode)|\(query)|\(offset)") {
        loading=true
        do {try await Task.sleep(for:.milliseconds(query.isEmpty ? 0:180))} catch {return}
        guard !Task.isCancelled else {return}
        refresh();loading=false
      }
  }
}

private struct NativeGlyphPreview: NSViewRepresentable {
  let glyph:FontGlyph,type:Typography
  let nominalPoints:Double
  func makeNSView(context:Context)->GlyphPreviewView {GlyphPreviewView()}
  func updateNSView(_ view:GlyphPreviewView,context:Context) {
    view.glyph=glyph;view.type=type;view.nominalPoints=nominalPoints;view.needsDisplay=true
  }
}

private final class GlyphPreviewView:NSView {
  var glyph:FontGlyph?,type=Typography(),nominalPoints=48.0
  override func hitTest(_ point:NSPoint)->NSView? {nil}
  override func draw(_ dirtyRect:NSRect) {
    guard let glyph,let cg=NSGraphicsContext.current?.cgContext else {return}
    var font=TypographyEngine.font(type,size:38,opticalPointSize:type.opticalSizing != nil ? nominalPoints:nil)
    if GlyphCatalog.canonicalName(font) != glyph.fontName {
      var style=type;style.fontName=glyph.fontName;font=TypographyEngine.font(style,size:38,opticalPointSize:style.opticalSizing != nil ? nominalPoints:nil)
    }
    guard var id=try? GlyphCatalog.resolve(glyph,font:font,sourceFace:type.opticalSizing != nil ? type.fontName:nil) else {return}
    var box=CGRect.zero
    CTFontGetBoundingRectsForGlyphs(font as CTFont,.default,&id,&box,1)
    guard !box.isEmpty else {return}
    let scale=min(1,(bounds.width-12)/max(1,box.width),(bounds.height-8)/max(1,box.height))
    cg.saveGState()
    cg.setFillColor(FormColor.color("#292D2C").cgColor)
    cg.translateBy(x:(bounds.width-box.width*scale)/2-box.minX*scale,y:(bounds.height-box.height*scale)/2-box.minY*scale)
    cg.scaleBy(x:scale,y:scale)
    var position=CGPoint.zero
    CTFontDrawGlyphs(font as CTFont,&id,&position,1,cg)
    cg.restoreGState()
  }
}
