import Foundation

extension Project {
  /// Transfer whole managed sizes only; source/guide identities and their recorded baselines move
  /// together. Edited or nonrigid sources require explicit detachment before transferring.
  public mutating func transferGarmentBlockBindings(from sourceID:UUID,to targetID:UUID,
    moved:Set<UUID>,mapping:[UUID:UUID],destination:Artwork)throws {
    guard var blocks=garmentBlocks else {return}
    for bi in blocks.indices {
      let sourceBlock=blocks[bi]
      let affected=Set(sourceBlock.bindings.filter{$0.objectID==sourceID && moved.contains($0.elementID)}.map(\.sizeID))
      guard !affected.isEmpty else {continue}
      var subset=sourceBlock
      subset.bindings=subset.bindings.filter{affected.contains($0.sizeID)}
      subset.seams=subset.seams.filter{affected.contains($0.sizeID)}
      for size in affected {
        let refs=subset.bindings.filter{$0.sizeID==size}
        guard refs.count==3,refs.allSatisfy({$0.objectID==sourceID && moved.contains($0.elementID)}) else {
          throw FormError.invalid("Move all front/back/elastic pieces of a managed size together, or detach that size's metadata first.")
        }
      }
      let conflicts=try GarmentBlockSources.conflicts(subset,in:self)
      guard conflicts.isEmpty else {throw FormError.invalid("Detach or review the edited/nonrigid managed size before transferring it.\n"+conflicts.joined(separator:"\n"))}
      guard let old=objects.first(where:{$0.id==sourceID})?.artwork else {throw FormError.missing("The managed source disappeared.")}
      for i in blocks[bi].bindings.indices where affected.contains(blocks[bi].bindings[i].sizeID) {
        let previous=blocks[bi].bindings[i]
        guard let id=mapping[previous.elementID],let e=destination.elements.first(where:{$0.id==id}),
          GarmentBlockSources.isRigid(destination.worldTransform(e)) else {
          throw FormError.invalid("A managed-size transfer must retain its complete rigid physical source.")
        }
        blocks[bi].bindings[i].objectID=targetID;blocks[bi].bindings[i].elementID=id
        blocks[bi].bindings[i].fingerprint=try GarmentBlockSources.fingerprint(e)
      }
      for i in blocks[bi].seams.indices where affected.contains(blocks[bi].seams[i].sizeID) {
        let ref=blocks[bi].seams[i]
        guard let seam=old.sewingSeams?.first(where:{$0.id==ref.seamID}),
          let first=mapping[seam.first.elementID],let second=mapping[seam.second.elementID] else {
          throw FormError.invalid("Both endpoints of a managed side seam must transfer together.")
        }
        let a=destination.remappingSewingEnd(seam.first,to:first,from:old)
        let b=destination.remappingSewingEnd(seam.second,to:second,from:old)
        let matches=(destination.sewingSeams ?? []).filter{$0.first==a && $0.second==b && $0.name==seam.name && $0.reversed==seam.reversed && $0.tolerance==seam.tolerance}
        guard matches.count==1 else {throw FormError.invalid("A managed seam transfer is ambiguous; detach the managed size explicitly.")}
        blocks[bi].seams[i].objectID=targetID;blocks[bi].seams[i].seamID=matches[0].id
        blocks[bi].seams[i].fingerprint=try GarmentBlockSources.fingerprint(matches[0])
      }
    }
    garmentBlocks=blocks
  }
}
