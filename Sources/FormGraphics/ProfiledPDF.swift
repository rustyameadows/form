import AppKit
import FormCore
import Quartz

/// Quartz applies the ICC conversion to text, paths, shadings, and images while
/// copying PDF pages. An OutputIntent on its own only labels the output condition.
@MainActor public enum ProfiledPDF {
  public static func convert(_ source: Data, profile: ICCOutputProfile, title: String = "FORM artwork") throws -> Data {
    guard source.count <= 512_000_000, let provider = CGDataProvider(data: source as CFData),
      let document = CGPDFDocument(provider), !document.isEncrypted,
      (1...1000).contains(document.numberOfPages)
    else { throw FormError.invalid("Color conversion needs an unlocked PDF with 1–1000 pages under 512 MB.") }
    let intent: [String: Any] = [
      kCGPDFXOutputIntentSubtype as String: "GTS_PDFX",
      kCGPDFXOutputConditionIdentifier as String: "FORM-ICC-" + profile.reference.sha256,
      kCGPDFXInfo as String: profile.reference.name,
      kCGPDFXDestinationOutputProfile as String: profile.space,
    ]
    guard let filter = QuartzFilter(outputIntents: [intent]) else {
      throw FormError.invalid("ColorSync could not build the selected output conversion.")
    }
    let data = NSMutableData()
    var box = document.page(at: 1)!.getBoxRect(.mediaBox)
    let info: [String: Any] = [kCGPDFContextOutputIntent as String: intent,
      kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "FORM · ICC converted output"]
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary),
      filter.apply(to: context)
    else { throw FormError.invalid("ColorSync could not initialize PDF conversion.") }
    defer { filter.remove(from: context) }
    for index in 1...document.numberOfPages {
      guard let page = document.page(at: index), page.rotationAngle % 360 == 0 else {
        throw FormError.invalid("Normalize rotated PDF pages before profile conversion.")
      }
      var pageInfo: [String: Any] = [:]
      for (key, kind) in [(kCGPDFContextMediaBox, CGPDFBox.mediaBox), (kCGPDFContextCropBox, .cropBox),
        (kCGPDFContextTrimBox, .trimBox), (kCGPDFContextBleedBox, .bleedBox), (kCGPDFContextArtBox, .artBox)] {
        var rect = page.getBoxRect(kind)
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
          rect.width > 0, rect.height > 0, rect.width <= 300_000, rect.height <= 300_000 else {
          throw FormError.invalid("A PDF page has invalid physical bounds.")
        }
        pageInfo[key as String] = Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
      }
      context.beginPDFPage(pageInfo as CFDictionary)
      context.drawPDFPage(page)
      context.endPDFPage()
    }
    context.closePDF()
    return data as Data
  }
}
