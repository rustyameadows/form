import Foundation

extension Project {
  public func publicationDocument(for objectID:UUID)->PublicationDocument? {publications?.first{$0.pages.contains{$0.objectID==objectID}}}
  public func removingPublicationFurniture(from artwork:Artwork,objectID:UUID)->Artwork {
    guard let document=publicationDocument(for:objectID),let page=document.pages.first(where:{$0.objectID==objectID}) else{return artwork}
    let roots=Set((document.masters ?? []).map{ComponentCommands.derivedID(page.id,$0.id)})
    var result=artwork;let removed=artwork.descendants(of:roots).union(roots)
    result.elements.removeAll{removed.contains($0.id)};return result
  }
  /// Shared runtime composition for Canvas, physical faces, thumbnails and PDF.
  /// The returned groups are locked; callers edit the original master artboard.
  public func resolvingPublicationFurniture(in artwork:Artwork,objectID:UUID)->Artwork {
    guard let document=publicationDocument(for:objectID),let page=document.pages.first(where:{$0.objectID==objectID}) else{return artwork}
    var result=removingPublicationFurniture(from:artwork,objectID:objectID),behind:[ArtworkElement]=[],above:[ArtworkElement]=[]
    let tokens=["{{page.number}}":document.pageNumber(for:objectID) ?? "","{{page.label}}":document.pageLabel(for:objectID) ?? "",
      "{{page.total}}":String(document.pages.count),"{{publication.name}}":document.name,"{{chapter.title}}":document.chapterTitle(for:objectID) ?? ""]
    for master in document.appliedMasters(for:objectID) {
      guard let source=objects.first(where:{$0.id==master.sourceObjectID}),let stored=source.artwork,
        let art=try? resolvingComponents(in:stored,keepingSwatchReferences:true) else{continue}
      let rootID=ComponentCommands.derivedID(page.id,master.id),mapping=Dictionary(uniqueKeysWithValues:art.elements.map{($0.id,ComponentCommands.derivedID(rootID,$0.id))})
      var root=ArtworkElement(kind:"group",x:master.x,y:master.y,width:source.artworkSize.x,height:source.artworkSize.y)
      root.id=rootID;root.name=master.name;root.contentSize=source.artworkSize;root.locked=true
      var elements=[root]
      for original in art.elements {
        var copy=original;copy.id=mapping[original.id]!;copy.parentID=original.parentID.flatMap{mapping[$0]} ?? rootID
        copy.clipID=original.clipID.flatMap{mapping[$0]};copy.locked=true
        copy.listItems=copy.listItems?.map{item in
          var value=item;value.id=ComponentCommands.derivedID(rootID,item.id);value.listID=ComponentCommands.derivedID(rootID,item.listID);value.resolvedNumber=nil;return value
        }
        if copy.kind=="text" {
          for token in tokens.keys.sorted() {
            var matches:[NSRange]=[],cursor=0
            let text=copy.text as NSString
            while cursor<text.length {
              let match=text.range(of:token,range:NSRange(location:cursor,length:text.length-cursor))
              if match.location==NSNotFound {break};matches.append(match);cursor=NSMaxRange(match)
            }
            for match in matches.reversed() {if let edited=try? PublicationTextEdits.replacing(copy,range:match,with:tokens[token]!,derivedParagraphNamespace:copy.id) {copy=edited}}
          }
        }
        elements.append(copy)
      }
      if master.behind {behind+=elements}else{above+=elements}
    }
    result.elements=behind+result.elements+above;return result
  }
  public func validatePublicationMasters(_ document:PublicationDocument)throws {
    let pageIDs=Set((publications ?? []).flatMap(\.pages).map(\.objectID))
    var total=0
    for master in document.masters ?? [] {
      guard !master.name.isEmpty,master.name.count<=160,master.x.isFinite,master.y.isFinite,abs(master.x)<=100000,abs(master.y)<=100000,
        let source=objects.first(where:{$0.id==master.sourceObjectID}),source.recipeID=="artboard",!source.isCanvasWorkspace,
        source.artworkSourceID==nil,!pageIDs.contains(source.id),let art=source.artwork,
        !art.elements.contains(where:{$0.storyFrame != nil}) else{throw FormError.invalid("A publication master references an independent editable artboard outside the page sequence, without linked body-text capacity.")}
      let expanded=try resolvingComponents(in:art,keepingSwatchReferences:true)
      guard !expanded.elements.contains(where:{$0.storyFrame != nil}) else{throw FormError.invalid("Master components cannot introduce linked body-text capacity through nested sources.")}
      total+=expanded.elements.count+1
      guard total<=5000 else{throw FormError.invalid("Publication masters support at most 5,000 resolved furniture layers per page.")}
      for element in expanded.elements where element.kind=="text" {
        let base=element.text.utf16.count
        let tokens=["{{page.number}}","{{page.label}}","{{page.total}}","{{publication.name}}","{{chapter.title}}"]
        let occurrences=tokens.reduce(0){$0+element.text.components(separatedBy:$1).count-1}
        guard base+occurrences*1000<=100000 else{throw FormError.invalid("Running-furniture token expansion must stay within the bounded text source budget.")}
      }
    }
  }
}
