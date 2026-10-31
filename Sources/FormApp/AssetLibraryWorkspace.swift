import AppKit
import SwiftUI

@MainActor struct StudioAssetThumbnail:View {
  @ObservedObject var library:StudioAssetLibrary
  let asset:StudioAsset
  var maxPixelSize=240
  @State private var image:NSImage?
  @State private var loading=true
  var body:some View {
    ZStack {
      Color(nsColor:Palette.surfaceNS)
      if let image {Image(nsImage:image).resizable().scaledToFit()}
      else {VStack(spacing:8) {
        Image(systemName:asset.isMissing ? "exclamationmark.triangle":asset.kind.symbol).font(.system(size:30,weight:.light))
        Text(asset.isMissing ? "Original file missing":asset.kind.title).font(.system(size:10))
      }.foregroundStyle(Palette.secondary)
        if loading {ProgressView().controlSize(.small).frame(maxHeight:.infinity,alignment:.bottom).padding(8)}
      }
    }.task(id:"\(asset.id)-\(asset.sha256 ?? String(asset.modifiedAt.timeIntervalSince1970))-\(asset.isMissing)-\(maxPixelSize)") {
      image=nil;loading=true
      let next=await library.thumbnail(for:asset,maxPixelSize:maxPixelSize)
      guard !Task.isCancelled else{return};image=next;loading=false
    }
  }
}

@MainActor struct AssetLibraryWorkspace:View {
  @ObservedObject var library:StudioAssetLibrary
  var onClose:(()->Void)?=nil
  var onUseInCanvas:((StudioAsset)->Void)?=nil
  var onUseAsReference:((StudioAsset)->Void)?=nil
  var onOpenGeneration:((UUID)->Void)?=nil
  @State private var query=""
  @State private var origin:StudioAssetOrigin?
  @State private var kind:StudioAssetKind?
  @State private var projectID:UUID?
  @State private var favoritesOnly=false
  @State private var list=false
  @State private var selectedID:UUID?
  @State private var renameID:UUID?
  @State private var renameDraft=""
  @State private var issue:String?
  private var filtered:[StudioAsset] {
    let words=query.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current).split(whereSeparator:\.isWhitespace)
    return library.visibleItems.filter {item in
      guard origin==nil || item.origin==origin,kind==nil || item.kind==kind,projectID==nil || item.metadata.projectID==projectID,!favoritesOnly || item.favorite else{return false}
      let text=[item.name,item.filename,item.metadata.projectName ?? "",item.metadata.prompt ?? "",item.metadata.provider ?? "",item.kind.title].joined(separator:" ").folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
      return words.allSatisfy{text.contains($0)}
    }
  }
  private var selected:StudioAsset? {selectedID.flatMap{library.asset(id:$0)}}
  private var projects:[(id:UUID,name:String)] {
    var values=[UUID:String]()
    for item in library.items {if let id=item.metadata.projectID {values[id]=item.metadata.projectName ?? "Project"}}
    return values.map{(id:$0.key,name:$0.value)}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
  }
  var body:some View {
    VStack(spacing:0) {
      HStack(spacing:12) {
        Text("Asset Library").font(.system(size:17,weight:.semibold))
        Spacer()
        if library.isLoading {ProgressView().controlSize(.small)}
        Button {Task{await library.refresh()}} label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.borderless).help("Refresh project Assets and Exports")
        Button("Import files…",action:importFiles).buttonStyle(.bordered)
        if let onClose {AppCloseButton("Close Asset Library",action:onClose)}
      }.padding(16)
      HStack(spacing:12) {
        Image(systemName:"magnifyingglass").foregroundStyle(Palette.secondary)
        TextField("Search names, prompts, or projects",text:$query).textFieldStyle(InspectorTextFieldStyle()).accessibilityLabel("Search Asset Library")
        Picker("Layout",selection:$list) {Image(systemName:"square.grid.2x2").tag(false);Image(systemName:"list.bullet").tag(true)}.labelsHidden().pickerStyle(.segmented).frame(width:76)
      }.padding(.horizontal,16).padding(.bottom,12)
      HStack(spacing:10) {
        Picker("Show",selection:$origin) {Text("All assets").tag(StudioAssetOrigin?.none);ForEach(StudioAssetOrigin.allCases,id:\.self){Text($0.title).tag(Optional($0))}}.labelsHidden().inspectorPicker().frame(width:160)
        Picker("Type",selection:$kind) {Text("All types").tag(StudioAssetKind?.none);ForEach(StudioAssetKind.allCases,id:\.self){Text($0.title).tag(Optional($0))}}.labelsHidden().inspectorPicker().frame(width:150)
        Picker("Project",selection:$projectID) {Text("All projects").tag(UUID?.none);ForEach(projects,id:\.id){Text($0.name).tag(Optional($0.id))}}.labelsHidden().inspectorPicker().frame(width:200)
        Toggle(isOn:$favoritesOnly){Image(systemName:favoritesOnly ? "star.fill":"star")}.toggleStyle(.button).help("Favorites only")
        Spacer(minLength:0)
      }.font(.system(size:11)).padding(.horizontal,16).padding(.bottom,12)
      Divider()
      if let text=issue ?? library.issue {Text(text).font(.system(size:11)).foregroundStyle(Palette.accent).frame(maxWidth:.infinity,alignment:.leading).padding(12)}
      HStack(spacing:0) {
        browse
        if let selected {Divider();details(selected).frame(width:310)}
      }
      Divider()
      HStack {
        Text("\(filtered.count) assets").font(.system(size:10,design:.monospaced))
        Spacer()
        Text("Project files stay in their original folders.").font(.system(size:10)).foregroundStyle(Palette.secondary)
      }.padding(.horizontal,16).padding(.vertical,10)
    }.background(Palette.paper).foregroundStyle(Palette.ink)
      .task {await library.refresh()}
      .alert("Rename asset",isPresented:Binding(get:{renameID != nil},set:{if !$0{renameID=nil}})) {
        TextField("Name",text:$renameDraft)
        Button("Save") {if let id=renameID {act{try library.rename(id,to:renameDraft)}};renameID=nil}
        Button("Cancel",role:.cancel){renameID=nil}
      }
  }
  @ViewBuilder private var browse:some View {
    let values=filtered
    if values.isEmpty {
      VStack(spacing:14) {
        Image(systemName:library.isLoading ? "tray":"photo.on.rectangle.angled").font(.system(size:35,weight:.ultraLight)).foregroundStyle(Palette.secondary)
        Text(library.isLoading ? "Indexing your project files…":library.visibleItems.isEmpty ? "Your assets will appear here":"No matching assets").font(.system(size:14,weight:.medium))
        Text("Import local files, save a Studio image, or generate a demo still.").font(.system(size:11)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
        Button("Import files…",action:importFiles)
      }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
    }else {
      ScrollView {
        if list {
          LazyVStack(spacing:3){ForEach(values){item in assetRow(item)}}.padding(12)
        }else {
          LazyVGrid(columns:[GridItem(.adaptive(minimum:140,maximum:200),spacing:12)],spacing:12){ForEach(values){item in assetCard(item)}}.padding(16)
        }
      }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
  }
  private func assetCard(_ item:StudioAsset)->some View {
    Button {selectedID=item.id} label:{
      VStack(alignment:.leading,spacing:7) {
        StudioAssetThumbnail(library:library,asset:item).frame(height:120).clipShape(RoundedRectangle(cornerRadius:8))
        HStack {Text(item.name).lineLimit(1);Spacer(minLength:0);if item.favorite{Image(systemName:"star.fill").font(.system(size:9))}}
        HStack {Text(item.isMock ? "DEMO · Generated":item.origin.title);Spacer(minLength:0);Text(item.kind.title)}.font(.system(size:9)).foregroundStyle(Palette.secondary)
      }.font(.system(size:11)).padding(7).background(selectedID==item.id ? Palette.accent.opacity(0.07):.clear,in:RoundedRectangle(cornerRadius:10))
        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(selectedID==item.id ? Palette.accent:Palette.line,lineWidth:1))
    }.buttonStyle(.plain).contextMenu{actions(item)}.accessibilityLabel(item.name+(item.isMock ? ", demo generated asset":""))
  }
  private func assetRow(_ item:StudioAsset)->some View {
    Button {selectedID=item.id} label:{
      HStack(spacing:12) {
        StudioAssetThumbnail(library:library,asset:item).frame(width:62,height:48).clipShape(RoundedRectangle(cornerRadius:6))
        VStack(alignment:.leading,spacing:4) {Text(item.name).lineLimit(1);Text(item.metadata.projectName ?? item.origin.title).font(.system(size:10)).foregroundStyle(Palette.secondary)}
        Spacer(minLength:0)
        if item.isMock {Text("DEMO").font(.system(size:9,weight:.semibold)).foregroundStyle(Palette.accent)}
        if item.favorite {Image(systemName:"star.fill")}
        Text(item.kind.title).font(.system(size:10)).foregroundStyle(Palette.secondary)
      }.font(.system(size:11)).padding(7).background(selectedID==item.id ? Palette.accent.opacity(0.07):.clear,in:RoundedRectangle(cornerRadius:8))
    }.buttonStyle(.plain).contextMenu{actions(item)}
  }
  private func details(_ item:StudioAsset)->some View {
    ScrollView {
      VStack(alignment:.leading,spacing:16) {
        StudioAssetThumbnail(library:library,asset:item,maxPixelSize:1200).frame(height:230).clipShape(RoundedRectangle(cornerRadius:10))
        Text(item.name).font(.system(size:16,weight:.semibold)).textSelection(.enabled)
        if item.isMock {Label("Demo image · generated locally",systemImage:"sparkles").font(.system(size:11,weight:.medium)).foregroundStyle(Palette.accent)}
        if item.isMissing {Label("Original file is missing",systemImage:"exclamationmark.triangle").font(.system(size:11)).foregroundStyle(Palette.accent)}
        HStack {
          Button {act{try library.setFavorite(item.id,!item.favorite)}} label:{Label(item.favorite ? "Favorited":"Favorite",systemImage:item.favorite ? "star.fill":"star")}
          Button("Rename"){renameID=item.id;renameDraft=item.name}
        }.font(.system(size:11))
        metadata("Type",item.kind.title);metadata("Origin",item.origin.title)
        if let project=item.metadata.projectName {metadata("Project",project)}
        metadata("File",item.filename);metadata("Size",ByteCountFormatter.string(fromByteCount:item.byteCount,countStyle:.file))
        metadata("Added",item.createdAt.formatted(date:.abbreviated,time:.shortened))
        if let provider=item.metadata.provider {metadata("Provider",provider)}
        if let prompt=item.metadata.prompt,!prompt.isEmpty {VStack(alignment:.leading,spacing:5){Text("Prompt").font(.system(size:10,weight:.medium)).foregroundStyle(Palette.secondary);Text(prompt).font(.system(size:11)).textSelection(.enabled)}}
        if let options=item.metadata.options {ForEach(options.keys.sorted(),id:\.self){key in metadata(key,options[key] ?? "")}}
        if !item.metadata.sourceAssetIDs.isEmpty {metadata("Sources","\(item.metadata.sourceAssetIDs.count) linked assets")}
        if let hash=item.sha256 {metadata("SHA-256",hash)}
        Divider()
        VStack(alignment:.leading,spacing:10){actions(item)}.font(.system(size:11))
      }.padding(16)
    }
  }
  private func metadata(_ name:String,_ value:String)->some View {
    VStack(alignment:.leading,spacing:4){Text(name).font(.system(size:10,weight:.medium)).foregroundStyle(Palette.secondary);Text(value).font(.system(size:11)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
  }
  @ViewBuilder private func actions(_ item:StudioAsset)->some View {
    if item.kind == .image,!item.isMissing {
      if let onUseInCanvas {Button("Use in Canvas"){onUseInCanvas(item)}}
      if let onUseAsReference {Button("Use as reference"){Task {if await library.thumbnail(for:item,maxPixelSize:64) != nil {onUseAsReference(item)}else{issue="This file could not be decoded as an image."}}}}
    }
    if let id=item.metadata.generationID,let onOpenGeneration {Button("Open generation"){onOpenGeneration(id)}}
    Button("Save a copy…"){saveCopy(item)}.disabled(item.isMissing)
    Button("Reveal original file"){act{NSWorkspace.shared.activateFileViewerSelecting([try library.fileURL(for:item)])}}.disabled(item.isMissing)
    Button("Open original file"){act{NSWorkspace.shared.open(try library.fileURL(for:item))}}.disabled(item.isMissing)
    Button("Remove from Library",role:.destructive){act{try library.archive(item.id);if selectedID==item.id{selectedID=nil}}}.help("Keeps the original file and saved provenance.")
  }
  private func act(_ body:()throws->Void) {do{try body();issue=nil}catch{issue=error.localizedDescription}}
  private func importFiles() {
    let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=true
    panel.prompt="Import copies"
    panel.begin {response in guard response == .OK else{return};Task { @MainActor in
      for url in panel.urls {do{let item=try await library.importFile(url);selectedID=item.id;issue=nil}catch{issue=error.localizedDescription}}
    }}
  }
  private func saveCopy(_ item:StudioAsset) {
    let panel=NSSavePanel();panel.nameFieldStringValue=item.filename;panel.canCreateDirectories=true
    panel.begin {response in guard response == .OK,let url=panel.url else{return};act{try library.saveCopy(item.id,to:url,replaceExisting:true)}}
  }
}

/// Shared image inventory for Studio references. Choosing an item only changes
/// the caller's draft binding; no source or project edits are performed here.
@MainActor struct StudioAssetPicker:View {
  @ObservedObject var library:StudioAssetLibrary
  @Binding var selection:UUID?
  @State private var query=""
  @State private var issue:String?
  private var images:[StudioAsset] {library.visibleItems.filter{$0.kind == .image && !$0.isMissing && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))}}
  var body:some View {
    VStack(alignment:.leading,spacing:12) {
      TextField("Search image assets",text:$query).textFieldStyle(InspectorTextFieldStyle()).accessibilityLabel("Search reference images")
      if let issue {Text(issue).font(.system(size:11)).foregroundStyle(Palette.accent)}
      if images.isEmpty {Text("Import an image in the Asset Library to use it as a reference.").font(.system(size:11)).foregroundStyle(Palette.secondary).padding(.vertical,20)}
      ScrollView {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:110))],spacing:10) {
          ForEach(images){item in
            Button {Task {
              guard await library.thumbnail(for:item,maxPixelSize:64) != nil else{issue="This reference could not be decoded as an image.";return}
              selection=item.id;issue=nil
            }}label:{VStack(alignment:.leading,spacing:5){StudioAssetThumbnail(library:library,asset:item).frame(height:85);Text(item.name).font(.system(size:10)).lineLimit(1);if item.isMock{Text("DEMO").font(.system(size:9)).foregroundStyle(Palette.accent)}}}
              .buttonStyle(.plain).padding(5).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(selection==item.id ? Palette.accent:Palette.line))
          }
        }
      }
    }.padding(14).frame(minWidth:300,minHeight:220).task{await library.refresh()}
  }
}
