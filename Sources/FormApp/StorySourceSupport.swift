import AppKit
import FormCore

struct StorySourceFrameOption:Identifiable {
  let id:StoryFrameID
  let label:String
}

enum StorySourceStatistics {
  static func words(_ text:String)->Int {
    var count=0
    text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:.byWords){_,_,_,_ in count+=1}
    return count
  }
}

/// A readable, reflowing source surface. Magnification only changes this view;
/// physical story frames continue to use their authored type and dimensions.
final class StorySourceScrollView:NSScrollView {
  private var resizingDocument=false
  var onZoomChange:((Double)->Void)?
  override func magnify(with event:NSEvent){super.magnify(with:event);resizeDocument();onZoomChange?(Double(magnification))}
  override func tile(){super.tile();resizeDocument()}
  override func layout(){super.layout();resizeDocument()}
  func resizeDocument() {
    guard !resizingDocument,let text=documentView as? CanvasTextView,
      let container=text.textContainer,let layout=text.layoutManager else{return}
    resizingDocument=true;defer{resizingDocument=false}
    let width=max(120,contentView.bounds.width),inset=text.textContainerInset
    let available=max(64,width-inset.width*2)
    if abs(container.size.width-available)>0.5 {container.size.width=available}
    layout.ensureLayout(for:container)
    let height=max(contentView.bounds.height,ceil(layout.usedRect(for:container).maxY)+inset.height*2+20)
    if abs(text.frame.width-width)>0.5 || abs(text.frame.height-height)>0.5 {text.setFrameSize(.init(width:width,height:height))}
  }
}
