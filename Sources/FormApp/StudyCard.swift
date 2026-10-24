import AppKit
import FormCore
import SwiftUI

@MainActor private enum StudyPreviews {
  static let cache = NSCache<NSString, NSImage>()
  static func image(_ template: StudyTemplate, assets: URL) -> NSImage? {
    if let value = cache.object(forKey: template.id as NSString) { return value }
    guard let project = try? Samples.make(template.id) else { return nil }
    let image = TableSceneController.preview(
      project: project, size: .init(width: 720, height: 390), assets: assets, fitContents: true)
    cache.countLimit = 4
    cache.totalCostLimit = 8_000_000
    cache.setObject(image, forKey: template.id as NSString, cost: 720 * 390 * 4)
    return image
  }
}
struct StudyCard: View {
  @EnvironmentObject var store: StudioStore
  let template: StudyTemplate
  @State private var image: NSImage?
  @State private var hovering = false
  var body: some View {
    Button {
      store.createProject(template: template.id)
    } label: {
      HStack(spacing: 0) {
        ZStack {
          Palette.line
          if let image {
            Image(nsImage: image).resizable().scaledToFill()
          } else {
            Image(systemName: template.symbol).font(.system(size: 26, weight: .ultraLight))
          }
        }.frame(width: 138, height: 116).clipped()
        VStack(alignment: .leading, spacing: 7) {
          Text(template.title).font(.system(size: 13, weight: .semibold))
          Text(template.summary).font(.system(size: 10)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Label("Start study", systemImage: "arrow.up.right").font(
            .system(size: 9, weight: .medium)
          ).foregroundStyle(Palette.accent)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
      }.background(
        hovering ? Color.white : .white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)
      )
      .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(
        RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }.buttonStyle(.plain).onHover { hovering = $0 }
      .task { image = StudyPreviews.image(template, assets: store.repository.root) }
      .accessibilityLabel("Start \(template.title) study")
  }
}
