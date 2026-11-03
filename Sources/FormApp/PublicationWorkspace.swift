import AppKit
import CoreText
import FormCore
import FormGraphics
import SwiftUI

struct PublicationNavigator:View {
  @ObservedObject var session:ArtworkSession
  @ObservedObject var controller:PublicationWorkspaceController
  var maxHeight:CGFloat=600
  @EnvironmentObject private var store:StudioStore
  @State private var createOpen=false
  @State private var chapterOpen=false
  @State private var chapterName=""
  @State private var pageQuery=""
  @State private var pageQueryIssue:String?
  private var selectedRowID:UUID? {
    guard let page=controller.currentPageID else{return nil}
    return controller.showsSpreads ? controller.spreads.first{$0.pages.contains{$0.objectID==page}}?.id:page
  }
  var body:some View {
    VStack(spacing:0) {
      HStack {
        Text("PAGES").font(InspectorStyle.headingFont).tracking(1).foregroundStyle(Palette.secondary)
        Spacer()
        WorkspaceToolbarButton("Publication settings",symbol:"slider.horizontal.3",identifier:"publication-show-settings"){
          controller.showSettings()
        }
        AppCloseButton("Hide publication pages"){controller.close()}
      }.padding(.horizontal,12).frame(height:FloatingPanelStyle.headerHeight)
      InspectorDivider().padding(.horizontal,12)
      VStack(spacing:8) {
        HStack(spacing:4) {
          if !controller.documents.isEmpty {
            Picker("Publication",selection:Binding(get:{controller.publicationID?.uuidString ?? ""},set:{if let id=UUID(uuidString:$0){controller.open(id)}})) {
              ForEach(controller.documents){Text($0.name).tag($0.id.uuidString)}
            }.labelsHidden().pickerStyle(.menu).font(InspectorStyle.labelFont)
          }else {Text("No publication yet").font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)}
          Spacer(minLength:0)
          WorkspaceToolbarButton("New publication",symbol:"plus",identifier:"publication-create-open"){createOpen=true}
        }
        if let document=controller.document {
          let position=PublicationNavigationPosition(document:document,selectedPageID:controller.currentPageID,spreads:controller.showsSpreads)
          HStack(spacing:3) {
            WorkspaceToolbarButton("Previous spread",symbol:"chevron.left",identifier:"publication-previous"){controller.navigate(-1)}
              .disabled(!position.canNavigate(-1))
            Spacer(minLength:0)
            Text(position.title).font(InspectorStyle.labelFont).lineLimit(1).truncationMode(.middle)
              .accessibilityLabel("Current pages").accessibilityValue(position.title).accessibilityIdentifier("publication-current-pages")
            Spacer(minLength:0)
            WorkspaceToolbarButton("Next spread",symbol:"chevron.right",identifier:"publication-next"){controller.navigate(1)}
              .disabled(!position.canNavigate(1))
          }
          HStack(spacing:8) {
            Text("\(document.pages.count) pages").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
            Spacer(minLength:0)
            TextField("Go to page",text:$pageQuery).textFieldStyle(InspectorTextFieldStyle())
              .frame(width:92).accessibilityLabel("Go to page label").accessibilityIdentifier("publication-go-to-page")
              .help("Enter a printed page label, such as 18 or Front cover, then Return")
              .onChange(of:pageQuery){_,_ in pageQueryIssue=nil}
              .onSubmit{
                if let page=PublicationNavigationPosition.resolve(pageQuery,in:document) {
                  controller.focusPage(page);pageQuery="";pageQueryIssue=nil
                }else{pageQueryIssue="No page labelled ‘\(pageQuery)’."}
              }
          }
          Picker("Thumbnail layout",selection:$controller.showsSpreads){Text("Spreads").tag(true);Text("Pages").tag(false)}
            .labelsHidden().pickerStyle(.segmented).accessibilityIdentifier("publication-thumbnail-layout")
          if let pageQueryIssue {Text(pageQueryIssue).font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)}
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(alignment:.leading,spacing:12) {
                if controller.showsSpreads {
                  ForEach(controller.spreads) {spread in
                    VStack(alignment:.leading,spacing:4) {
                      if let title=spread.pages.compactMap(\.chapterTitle).first {Text(title).font(.system(size:10,weight:.medium)).foregroundStyle(Palette.secondary).lineLimit(1)}
                      HStack(alignment:.top,spacing:4) {
                        if spread.left==nil && document.layout?.facingPages==true {Color.clear.frame(width:92,height:128)}
                        ForEach(spread.pages){page in pageTile(page,document:document)}
                      }
                    }.id(spread.id)
                  }
                }else {ForEach(document.pages){page in pageTile(page,document:document).frame(maxWidth:.infinity).id(page.objectID)}}
              }.padding(.vertical,6)
            }.onChange(of:selectedRowID,initial:true){_,id in
              guard let id else{return}
              // A far thumbnail is not realized yet. The lazy stack knows its
              // outer row identity; nested page IDs inside a spread cannot be
              // used to locate that row until it has already been displayed.
              DispatchQueue.main.async {
                guard controller.isVisible,selectedRowID==id else{return}
                withAnimation(.easeOut(duration:0.15)){proxy.scrollTo(id,anchor:.center)}
              }
            }
          }.frame(maxHeight:.infinity)
          InspectorDivider()
          HStack(spacing:3) {
            WorkspaceToolbarButton("Add page after selection",symbol:"doc.badge.plus",identifier:"publication-add-page"){controller.addPage()}
            WorkspaceToolbarButton("Duplicate selected page",symbol:"plus.square.on.square",identifier:"publication-duplicate-page"){controller.duplicatePage()}.disabled(controller.currentPageID==nil)
            WorkspaceToolbarButton("New chapter",symbol:"text.badge.plus",identifier:"publication-new-chapter"){chapterName="Chapter \(controller.stories.count+1)";chapterOpen=true}
            Menu {
              if !controller.currentPageStories.isEmpty {
                Section("On this page") {ForEach(controller.currentPageStories){story in Button(story.name){controller.openStory(story.id)}}}
                Divider()
              }
              Section("All stories") {ForEach(controller.stories){story in Button(story.name){controller.openStory(story.id)}}}
            }label:{WorkspaceToolbarMenuLabel(symbol:"text.alignleft",value:"Stories")}
              .menuStyle(.borderlessButton).fixedSize().disabled(controller.stories.isEmpty)
              .help("Edit story text, formatting, notes and references").accessibilityLabel("Stories")
              .accessibilityIdentifier("publication-edit-current-story")
            Spacer(minLength:0)
            Menu {
              if let id=controller.currentPageID {
                Button("Move page earlier"){controller.movePage(id,by:-1)}
                Button("Move page later"){controller.movePage(id,by:1)}
                Divider()
                Button("Remove from publication"){controller.removePage(id)}
                Button("Delete page",role:.destructive){controller.removePage(id,deleteObject:true)}
              }
            }label:{Image(systemName:"ellipsis").frame(width:28,height:30)}.menuStyle(.borderlessButton).fixedSize()
          }
        }else {
          VStack(alignment:.leading,spacing:10) {
            Image(systemName:"book.closed").font(.system(size:24,weight:.light)).foregroundStyle(Palette.secondary)
            Text("Pages on your Canvas").font(.system(size:13,weight:.medium))
            Text("Create physical pages and linked text, then design them with the same Canvas tools.").font(InspectorStyle.labelFont).foregroundStyle(Palette.secondary)
            Button("New publication…"){createOpen=true}.buttonStyle(InspectorActionStyle()).accessibilityIdentifier("publication-create-empty")
          }.padding(.vertical,14)
        }
        if let issue=controller.issue {Text(issue).font(InspectorStyle.captionFont).foregroundStyle(Palette.accent).fixedSize(horizontal:false,vertical:true)}
      }.padding(12)
    }.frame(width:234).frame(maxHeight:maxHeight).floatingPanelSurface()
      .onChange(of:controller.publicationID){_,_ in pageQuery="";pageQueryIssue=nil}
      .popover(isPresented:$createOpen){PublicationCreateView(controller:controller).labInterface()}
      .popover(isPresented:$chapterOpen){
        VStack(alignment:.leading,spacing:14) {
          HStack {Text("New chapter").font(.system(size:15,weight:.semibold));Spacer();AppCloseButton("Close chapter settings"){chapterOpen=false}}
          TextField("Chapter title",text:$chapterName).textFieldStyle(InspectorTextFieldStyle()).accessibilityIdentifier("publication-chapter-name")
          Text("Adds one page and its own linked story. The source editor flows your words through its pages.").font(InspectorStyle.captionFont).foregroundStyle(Palette.secondary)
          Button("Create chapter"){if controller.newChapter(name:chapterName.trimmingCharacters(in:.whitespacesAndNewlines)) != nil {chapterOpen=false}}.buttonStyle(InspectorActionStyle()).disabled(chapterName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }.padding(18).frame(width:292).labInterface()
      }
  }
  private func pageTile(_ page:PublicationPage,document:PublicationDocument)->some View {
    let project=store.project
    let object=project?.objects.first{$0.id==page.objectID}
    let frame=session.frames.first{$0.object.id==page.objectID && $0.projection==nil}
    let stock=project.flatMap{project in frame.flatMap{CanvasPublicationSpreads.substrate(for:$0,project:project)}}
    let image=object.flatMap{object in project.flatMap{project in
      project.surfaceArtwork(object).flatMap{artwork in
        PublicationThumbnailCache.shared.image(projectID:project.id,objectID:object.id,artwork:artwork,
          width:object.artworkSize.x,height:object.artworkSize.y,assets:session.assets,paperColor:stock?.color,paperOpacity:stock?.opacity ?? 1)
      }
    }}
    return PublicationPageThumbnail(title:document.pageLabel(for:page.objectID) ?? "—",subtitle:page.chapterTitle ?? object?.name ?? "Missing page",image:image,selected:controller.currentPageID==page.objectID,identifier:"publication-page-"+page.objectID.uuidString){controller.focusPage(page.objectID)}
      .frame(width:controller.showsSpreads ? 92:174,height:controller.showsSpreads ? 128:190)
      .contextMenu {
        Button("Open page"){controller.focusPage(page.objectID)}
        Button("Duplicate page"){controller.duplicatePage(page.objectID)}
        Button("Move earlier"){controller.movePage(page.objectID,by:-1)}
        Button("Move later"){controller.movePage(page.objectID,by:1)}
        Divider()
        Button("Remove from publication"){controller.removePage(page.objectID)}
        Button("Delete page",role:.destructive){controller.removePage(page.objectID,deleteObject:true)}
      }
  }
}

struct PublicationCreateView:View {
  @ObservedObject var controller:PublicationWorkspaceController
  @Environment(\.dismiss) private var dismiss
  @State private var name="Untitled publication"
  @State private var width=148.0
  @State private var height=210.0
  @State private var count=4.0
  @State private var columns=1.0
  @State private var gutter=8.0
  @State private var margin=14.0
  @State private var facing=true
  @State private var linkedBody=true
  var body:some View {
    VStack(alignment:.leading,spacing:14) {
      HStack {Text("New publication").font(.system(size:16,weight:.semibold));Spacer();AppCloseButton("Close publication settings"){dismiss()}}
      TextField("Publication name",text:$name).textFieldStyle(InspectorTextFieldStyle()).accessibilityIdentifier("publication-create-name")
      HStack(spacing:10) {
        ArtworkUnitField("Width",value:width,unit:.mm){width=$0}
        ArtworkUnitField("Height",value:height,unit:.mm){height=$0}
      }
      HStack(spacing:10) {
        ScalarArtworkField("Pages",value:count,unit:""){count=$0.rounded()}
        ScalarArtworkField("Columns",value:columns,unit:""){columns=$0.rounded()}
      }
      HStack(spacing:10) {
        ArtworkUnitField("Margins",value:margin,unit:.mm){margin=$0}
        ArtworkUnitField("Gutter",value:gutter,unit:.mm){gutter=$0}
      }
      Toggle("Facing pages",isOn:$facing).inspectorToggle()
      Toggle("Linked body text",isOn:$linkedBody).inspectorToggle()
      if let issue=controller.issue {Text(issue).font(InspectorStyle.captionFont).foregroundStyle(Palette.accent)}
      WorkspaceToolbarButton("Create publication",symbol:"book.closed",showsTitle:true,identifier:"publication-create-commit"){
        if controller.create(name:name.trimmingCharacters(in:.whitespacesAndNewlines),width:width,height:height,pageCount:Int(count),columns:Int(columns),gutter:gutter,margins:.init(top:margin,right:margin,bottom:margin,left:margin),facingPages:facing,linkedBody:linkedBody) != nil {dismiss()}
      }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !(1...200).contains(count) || !(1...4).contains(columns) || width<20 || height<20 || margin<0 || gutter<0)
    }.padding(18).frame(width:350)
  }
}

private struct PublicationPageThumbnail:NSViewRepresentable {
  var title:String,subtitle:String,image:NSImage?,selected:Bool,identifier:String,action:()->Void
  func makeCoordinator()->Coordinator{Coordinator(action)}
  func makeNSView(context:Context)->PublicationPageNativeButton {
    let button=PublicationPageNativeButton();button.isBordered=false;button.setButtonType(.momentaryChange);button.focusRingType = .exterior
    button.target=context.coordinator;button.action=#selector(Coordinator.press(_:));return button
  }
  func updateNSView(_ button:PublicationPageNativeButton,context:Context){
    context.coordinator.action=action;button.pageLabel=title;button.pageTitle=subtitle;button.thumbnail=image;button.selected=selected
    button.toolTip=subtitle;button.setAccessibilityLabel("Page "+title+", "+subtitle);button.setAccessibilityIdentifier(identifier);button.needsDisplay=true
  }
  func sizeThatFits(_ proposal:ProposedViewSize,nsView:PublicationPageNativeButton,context:Context)->CGSize?{.init(width:proposal.width ?? 92,height:proposal.height ?? 128)}
  static func dismantleNSView(_ view:PublicationPageNativeButton,coordinator:Coordinator){view.target=nil;view.action=nil;coordinator.action={}}
  final class Coordinator:NSObject {var action:()->Void;init(_ action:@escaping()->Void){self.action=action};@objc func press(_ sender:NSButton){if sender.isEnabled {action()}}}
}

final class PublicationPageNativeButton:NSButton {
  var pageLabel="",pageTitle="",thumbnail:NSImage?,selected=false
  override var isFlipped:Bool{true}
  override func isAccessibilityElement()->Bool{true}
  override func accessibilityRole()->NSAccessibility.Role?{.button}
  override func accessibilityValue()->Any?{selected ? "Selected":""}
  override func accessibilityPerformPress()->Bool{guard isEnabled,action != nil,target != nil else{return false};performClick(nil);return true}
  override func hitTest(_ point:NSPoint)->NSView?{!isHiddenOrHasHiddenAncestor && alphaValue>0 && bounds.contains(convert(point,from:superview)) ? self:nil}
  /// Resolve the house SF Mono face once, then retain a concrete immutable
  /// CoreText font. AppKit's string-drawing bridge copies dynamic UI font/color
  /// attributes during view reuse; its copy path can raise an NSException.
  static let regularLabelFont=labelFont(weight:.regular)
  static let selectedLabelFont=labelFont(weight:.medium)
  private static func labelFont(weight:NSFont.Weight)->CTFont {
    let system=NSFont.monospacedSystemFont(ofSize:10,weight:weight)
    let graphics=CTFontCopyGraphicsFont(system as CTFont,nil)
    return CTFontCreateWithGraphicsFont(graphics,10,nil,nil)
  }
  static func labelLine(_ value:String,selected:Bool,width:CGFloat,color:CGColor)->CTLine? {
    guard !value.isEmpty,width.isFinite,width>0 else{return nil}
    let font=selected ? selectedLabelFont:regularLabelFont
    let attributes=[kCTFontAttributeName as String:font,kCTForegroundColorAttributeName as String:color] as [String:Any]
    guard let text=CFAttributedStringCreate(nil,value as CFString,attributes as CFDictionary) else{return nil}
    let line=CTLineCreateWithAttributedString(text)
    guard CTLineGetTypographicBounds(line,nil,nil,nil)>Double(width) else{return line}
    guard let tokenText=CFAttributedStringCreate(nil,"…" as CFString,attributes as CFDictionary) else{return nil}
    return CTLineCreateTruncatedLine(line,Double(width),.end,CTLineCreateWithAttributedString(tokenText))
  }
  override func draw(_ rect:NSRect){
    guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>10,bounds.height>22 else{return}
    let outline=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:8,yRadius:8)
    if selected || isHighlighted {Palette.accentNS.withAlphaComponent(isHighlighted ? 0.16:0.08).setFill();outline.fill()}
    if selected {Palette.accentNS.withAlphaComponent(0.55).setStroke();outline.lineWidth=1;outline.stroke()}
    let available=bounds.insetBy(dx:8,dy:8),labelHeight=18.0
    if let thumbnail,thumbnail.size.width.isFinite,thumbnail.size.height.isFinite,
      thumbnail.size.width>0,thumbnail.size.height>0,available.height>labelHeight {
      let scale=min(available.width/thumbnail.size.width,(available.height-labelHeight)/thumbnail.size.height)
      let size=CGSize(width:thumbnail.size.width*scale,height:thumbnail.size.height*scale)
      let box=CGRect(x:bounds.midX-size.width/2,y:available.minY,width:size.width,height:size.height)
      NSColor.white.setFill();NSBezierPath(rect:box).fill()
      thumbnail.draw(in:box,from:.zero,operation:.sourceOver,fraction:isEnabled ? 1:0.4,respectFlipped:true,hints:nil)
      NSColor(Palette.line).setStroke();let border=NSBezierPath(rect:box);border.lineWidth=0.5;border.stroke()
    }
    let labelBox=CGRect(x:5,y:bounds.maxY-22,width:bounds.width-10,height:16)
    let sourceColor=selected ? Palette.accentNS:Palette.secondaryNS
    let color=(sourceColor.usingColorSpace(.sRGB) ?? NSColor.labelColor).cgColor
    if let context=NSGraphicsContext.current?.cgContext,
      let line=Self.labelLine(pageLabel,selected:selected,width:labelBox.width,color:color) {
      var ascent:CGFloat=0,descent:CGFloat=0
      let width=CTLineGetTypographicBounds(line,&ascent,&descent,nil)
      context.saveGState();context.clip(to:labelBox);context.textMatrix = .identity
      context.translateBy(x:labelBox.midX-CGFloat(width)/2,y:labelBox.midY+(ascent-descent)/2)
      context.scaleBy(x:1,y:-1);context.textPosition = .zero;CTLineDraw(line,context);context.restoreGState()
    }
    if window?.firstResponder === self {NSColor.keyboardFocusIndicatorColor.setStroke();outline.lineWidth=2;outline.stroke()}
  }
}
