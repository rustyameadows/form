import CryptoKit
import Foundation

/// Memoizes one pure, fully validated source-to-net result. Project ownership,
/// artwork availability, fallback stock, receiving paths and presentation poses
/// remain independently validated by their callers.
final class PlanarConstructionNetCache:@unchecked Sendable {
  struct Usage:Equatable,Sendable {
    var hits:Int
    var solves:Int
    var failedSolves:Int
    var bypasses:Int
    let maximumEntries:Int
    let maximumCostBytes:Int
  }
  private final class Entry:NSObject {
    let canonicalSource:Data
    let net:PaperNet
    init(source:Data,net:PaperNet){canonicalSource=source;self.net=net}
  }
  static let shared=PlanarConstructionNetCache()
  private let entries=NSCache<NSString,Entry>()
  private let counters=NSLock()
  private var hits=0,solves=0,failedSolves=0,bypasses=0
  private let maximumEntries=64,maximumCostBytes=16*1024*1024,maximumSourceBytes=4*1024*1024
  init(){entries.countLimit=maximumEntries;entries.totalCostLimit=maximumCostBytes}

  var usage:Usage {
    counters.lock();defer{counters.unlock()}
    return .init(hits:hits,solves:solves,failedSolves:failedSolves,bypasses:bypasses,
      maximumEntries:maximumEntries,maximumCostBytes:maximumCostBytes)
  }
  /// Internal test seam, never exposed through the app or public authoring API.
  func reset() {
    entries.removeAllObjects()
    counters.lock();defer{counters.unlock()}
    hits=0;solves=0;failedSolves=0;bypasses=0
  }
  private func countHit(){counters.lock();hits+=1;counters.unlock()}
  private func countBypass(){counters.lock();bypasses+=1;counters.unlock()}
  private func solve(_ body:()throws->PaperNet)throws->PaperNet {
    counters.lock();solves+=1;counters.unlock()
    do{return try body()}
    catch{counters.lock();failedSolves+=1;counters.unlock();throw error}
  }
  func resolve(_ source:PlanarConstructionDefinition,build:()throws->PaperNet)throws->PaperNet {
    // Obviously invalid, over-limit collections must reach the original cheap
    // validation guards without allocating a large serialized cache key.
    guard Self.boundedForEncoding(source) else{countBypass();return try solve(build)}
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    // Nonfinite authored values can fail encoding. Preserve the original
    // validator's diagnostic, rather than replacing it with an encoder error.
    guard let canonical=try? encoder.encode(source),canonical.count<=maximumSourceBytes else {
      countBypass();return try solve(build)
    }
    let key=SHA256.hash(data:canonical).map{String(format:"%02x",$0)}.joined() as NSString
    if let entry=entries.object(forKey:key),entry.canonicalSource==canonical {
      countHit();return entry.net
    }
    // Feature validation recursively resolves temporary nets. No cache lock is
    // held while solving; concurrent misses may safely duplicate pure work.
    let net=try solve(build)
    guard let encodedNet=try? encoder.encode(net) else{countBypass();return net}
    let points=net.panels.reduce(0){sum,panel in
      sum+panel.polygon.count+(panel.cutouts ?? []).reduce(0){$0+$1.polygon.count}
    }
    let cost=canonical.count+max(encodedNet.count,points*64+net.panels.count*512)+512
    guard cost<=maximumCostBytes else{countBypass();return net}
    entries.setObject(Entry(source:canonical,net:net),forKey:key,cost:cost)
    return net
  }
  private static func boundedForEncoding(_ source:PlanarConstructionDefinition)->Bool {
    guard (1...4).contains(source.version),!source.name.isEmpty,source.name.utf8.count<=160,
      source.parameters.count<=(source.version>=4 ? 128:64),
      source.panels.count<=(source.version>=4 ? 256:64),source.hinges.count<=256,source.joins.count<=128,
      (source.components?.count ?? 0)<=(source.version>=4 ? 128:32),
      (source.derived?.count ?? 0)<=256,(source.requirements?.count ?? 0)<=128,
      (source.connections?.count ?? 0)<=128,(source.solidChecks?.count ?? 0)<=128,
      (source.interiors?.count ?? 0)<=64,(source.groups?.count ?? 0)<=64,
      (source.jointAttachments?.count ?? 0)<=256 else{return false}
    let vertices=source.panels.reduce(0){sum,panel in
      return sum+panel.polygon.count+(panel.cutouts ?? []).reduce(0){$0+$1.polygon.count}
        + (panel.features?.outline?.count ?? 0)+(panel.features?.cutouts ?? []).reduce(0){$0+$1.polygon.count}
    }
    guard vertices<=(source.version>=4 ? 8192:2048) else{return false}
    if let controls=source.controls,
      controls.groups.count>32 || controls.parameters.count>128 || controls.measurements.count>128 || controls.poses.count>32 {return false}
    if let production=source.production,
      production.materials.count>64 || production.steps.count>128 || production.assumptions.count>64 || production.guides.count>256 || production.views.count>32 {return false}
    return true
  }
}
