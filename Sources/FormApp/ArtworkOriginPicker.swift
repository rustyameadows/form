import FormCore
import SwiftUI

struct ArtworkOriginPicker: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  private var origin: Point2 { element.transformOrigin ?? ArtworkTransforms.center }
  private let labels = ["Top left","Top center","Top right","Middle left","Center","Middle right",
    "Bottom left","Bottom center","Bottom right"]
  var body: some View {
    VStack(alignment:.leading,spacing:8) {
      HStack {
        Text("Transform origin").font(.system(size:10)).foregroundStyle(Palette.secondary)
        Spacer()
        Button("Reset") { session.setTransformOrigin(nil) }.font(.system(size:9)).buttonStyle(.plain)
          .disabled(element.transformOrigin == nil).accessibilityLabel("Reset transform origin to center")
      }
      HStack(spacing:12) {
        VStack(spacing:3) {
          ForEach(0..<3,id:\.self) { row in
            HStack(spacing:3) {
              ForEach(0..<3,id:\.self) { column in
                let point = Point2(Double(column)/2,Double(row)/2)
                Button { session.setTransformOrigin(point) } label: {
                  Circle().fill(origin == point ? Palette.accent : Palette.secondary.opacity(0.28))
                    .frame(width:7,height:7).frame(width:15,height:15)
                    .background(origin == point ? Palette.accent.opacity(0.1) : .clear,in:RoundedRectangle(cornerRadius:3))
                }.buttonStyle(.plain).help(labels[row*3+column])
                  .accessibilityLabel("Transform origin \(labels[row*3+column].lowercased())")
                  .accessibilityValue(origin == point ? "Selected" : "")
              }
            }
          }
        }
        VStack(spacing:6) {
          ScalarArtworkField("Origin X",value:origin.x*100,unit:"%") {
            session.setTransformOrigin(.init($0/100,origin.y))
          }
          ScalarArtworkField("Origin Y",value:origin.y*100,unit:"%") {
            session.setTransformOrigin(.init(origin.x,$0/100))
          }
        }
      }
      Text("Anchors rotation and numeric sizing. X/Y position uses artwork bounds.")
        .font(.system(size:9)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)
    }.help("Choose a reference point or enter percentages. 0% is top/left, 50% is center, and 100% is bottom/right. Values outside the layer set an external pivot.")
  }
}
