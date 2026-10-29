import Foundation

extension ProductObject {
  /// Canonical stored documents, including detached physical consumers. Linked
  /// sources are visited through their own object rather than through previews.
  public var storedArtworks:[Artwork] {
    var values=[artwork,paperConstruction?.insideArtwork].compactMap{$0}
    for binding in surfaceArtworkBindings ?? [] {
      if let art=binding.artwork{values.append(art)}
      values += (binding.storySnapshots ?? []).map{Artwork(elements:[$0.story.sourceElement])}
    }
    return values
  }
  /// Applies a project resource edit atomically to every stored document.
  public mutating func updateStoredArtworks(_ update:(inout Artwork)throws->Void)rethrows {
    var next=self
    if var art=next.artwork{try update(&art);next.artwork=art}
    if var art=next.paperConstruction?.insideArtwork{try update(&art);next.paperConstruction?.insideArtwork=art}
    for i in next.surfaceArtworkBindings?.indices ?? 0..<0 {
      if var art=next.surfaceArtworkBindings![i].artwork{try update(&art);next.surfaceArtworkBindings![i].artwork=art}
      for j in next.surfaceArtworkBindings![i].storySnapshots?.indices ?? 0..<0 {
        var art=Artwork(elements:[next.surfaceArtworkBindings![i].storySnapshots![j].story.sourceElement])
        try update(&art)
        next.surfaceArtworkBindings![i].storySnapshots![j].story.setSource(art.elements[0])
      }
    }
    self=next
  }
}
extension Project {
  public var storedArtworks:[Artwork] {objects.flatMap(\.storedArtworks)}
}
