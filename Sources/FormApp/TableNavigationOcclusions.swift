import SwiftUI

struct TableNavigationOcclusionKey: PreferenceKey {
  static var defaultValue: [CGRect] { [] }
  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
    value.append(contentsOf: nextValue().filter { $0.width > 0 && $0.height > 0 })
  }
}

extension View {
  func tableNavigationOcclusion() -> some View {
    background(GeometryReader { geometry in
      Color.clear.preference(key: TableNavigationOcclusionKey.self,
        value: [geometry.frame(in: .named("table-navigation-viewport"))])
    })
  }
}
