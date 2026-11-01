import Foundation
import FormCore
import FormGraphics

/// One bounded display snapshot per frame. Moving the frame or camera does not
/// change local artwork; editing, assets, exclusions and font changes do.
@MainActor final class CanvasPreparedArtworkCache {
  private struct Entry {
    var source: Artwork
    var assets: URL
    var excluding: Set<UUID>
    var renderer: ArtworkRenderer.Prepared
    var cost: Int
  }
  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  private var bytes = 0
  private let byteLimit: Int
  private let entryLimit: Int
  private(set) var builds = 0
  private(set) var hits = 0
  var count: Int { entries.count }
  var retainedBytes: Int { bytes }
  init(byteLimit: Int = 64*1024*1024, entryLimit: Int = 64) {
    self.byteLimit = byteLimit; self.entryLimit = entryLimit
  }
  func clear() { entries = [:]; order = []; bytes = 0 }
  func retain(_ ids: Set<UUID>) {
    for id in Array(entries.keys) where !ids.contains(id) { remove(id) }
  }
  private func remove(_ id: UUID) {
    if let old = entries.removeValue(forKey: id) { bytes -= old.cost }
    order.removeAll { $0 == id }
  }
  func renderer(frameID: UUID, source: Artwork, assets: URL, excluding: Set<UUID>) -> ArtworkRenderer.Prepared? {
    var local = source; local.canvasPosition = nil
    if let old = entries[frameID], old.source == local, old.assets == assets, old.excluding == excluding {
      hits += 1
      order.removeAll { $0 == frameID }; order.append(frameID)
      return old.renderer
    }
    remove(frameID)
    guard let renderer = try? ArtworkRenderer.Prepared(local, assets: assets, excluding: excluding) else { return nil }
    builds += 1
    let points = local.elements.reduce(0) { $0 + ($1.path?.contours.reduce(0) { $0 + $1.nodes.count } ?? 0) }
    let cost = max(1,local.elements.count)*1024 + points*128
    if cost <= byteLimit, entryLimit > 0 {
      while bytes+cost > byteLimit || entries.count >= entryLimit {
        guard let first = order.first else { break }; remove(first)
      }
      entries[frameID] = .init(source: local, assets: assets, excluding: excluding, renderer: renderer, cost: cost)
      bytes += cost; order.append(frameID)
    }
    return renderer
  }
}
