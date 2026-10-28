import Foundation

extension Typography {
  /// Stable order matters: Core Text resolves conflicting selectors last-wins.
  public var resolvedFeatureSelections: [(type: Int, selector: Int)] {
    Set(features.keys).union(featureSelections?.keys.map { $0 } ?? []).sorted().flatMap { type in
      (featureSelections?[type] ?? features[type].map { [$0] } ?? []).sorted().map { (type, $0) }
    }
  }

  /// nil uses the font default, false emits the explicit odd off selector.
  public func independentFeature(_ type: Int, selector: Int) -> Bool? {
    let on = selector - selector % 2
    let values = featureSelections?[type] ?? features[type].map { [$0] } ?? []
    if values.contains(on) { return true }
    if values.contains(on + 1) { return false }
    return nil
  }

  public mutating func setIndependentFeature(_ type: Int, selector: Int, value: Bool?) {
    let on = selector - selector % 2
    var values = featureSelections?[type] ?? features[type].map { [$0] } ?? []
    values.removeAll { $0 / 2 == on / 2 }
    if let value { values.append(value ? on : on + 1) }
    features.removeValue(forKey: type)
    var groups = featureSelections ?? [:]
    groups[type] = values.isEmpty ? nil : values.sorted()
    featureSelections = groups.isEmpty ? nil : groups
  }

  public mutating func resetFeature(_ type: Int) {
    features.removeValue(forKey: type)
    featureSelections?.removeValue(forKey: type)
    if featureSelections?.isEmpty == true { featureSelections = nil }
  }
}
