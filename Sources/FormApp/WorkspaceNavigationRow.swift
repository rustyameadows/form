import AppKit
import SwiftUI

/// One full-width native action shared by Canvas search and the Table list.
struct WorkspaceNavigationRow:NSViewRepresentable {
  var title:String
  var subtitle:String
  var symbol:String
  var selected=false
  var highlighted=false
  var statusSymbols:[String]=[]
  var accessibilityLabel:String
  var identifier:String
  var action:()->Void
  @Environment(\.isEnabled) private var enabled

  init(title:String,subtitle:String,symbol:String,selected:Bool=false,highlighted:Bool=false,statusSymbols:[String]=[],
    accessibilityLabel:String,identifier:String,action:@escaping()->Void) {
    self.title=title;self.subtitle=subtitle;self.symbol=symbol;self.selected=selected;self.highlighted=highlighted
    self.statusSymbols=statusSymbols;self.accessibilityLabel=accessibilityLabel;self.identifier=identifier;self.action=action
  }

  func makeCoordinator()->Coordinator {Coordinator(action:action)}
  func makeNSView(context:Context)->WorkspaceNavigationNativeButton {
    let button=WorkspaceNavigationNativeButton(frame:.zero)
    button.setButtonType(.momentaryChange);button.isBordered=false;button.focusRingType = .exterior
    button.target=context.coordinator;button.action=#selector(Coordinator.press(_:))
    updateNSView(button,context:context);return button
  }
  func updateNSView(_ button:WorkspaceNavigationNativeButton,context:Context) {
    context.coordinator.action=action
    button.rowTitle=title;button.subtitle=subtitle;button.symbol=symbol
    button.selected=selected;button.rowHighlighted=highlighted;button.statusSymbols=statusSymbols
    button.isEnabled=enabled;button.toolTip=title+" · "+subtitle
    button.setAccessibilityLabel(accessibilityLabel);button.setAccessibilityIdentifier(identifier)
    button.setAccessibilityHelp(subtitle)
    button.needsDisplay=true
  }
  func sizeThatFits(_ proposal:ProposedViewSize,nsView:WorkspaceNavigationNativeButton,context:Context)->CGSize? {
    .init(width:proposal.width ?? 208,height:40)
  }
  static func dismantleNSView(_ button:WorkspaceNavigationNativeButton,coordinator:Coordinator) {
    button.target=nil;button.action=nil;coordinator.action={}
  }
  final class Coordinator:NSObject {
    var action:()->Void
    init(action:@escaping()->Void){self.action=action;super.init()}
    @objc func press(_ sender:NSButton){if sender.isEnabled {action()}}
  }
}

final class WorkspaceNavigationNativeButton:NSButton {
  var rowTitle="",subtitle="",symbol="cube.transparent"
  var selected=false,rowHighlighted=false
  var statusSymbols:[String]=[]
  private var hovered=false
  private var tracking:NSTrackingArea?
  private var symbols:[String:(NSColor,NSImage)]=[:]
  override var isFlipped:Bool {true}
  override var intrinsicContentSize:NSSize {.init(width:NSView.noIntrinsicMetric,height:40)}
  override var alignmentRectInsets:NSEdgeInsets {.init(top:0,left:0,bottom:0,right:0)}
  override var acceptsFirstResponder:Bool {isEnabled}
  override func isAccessibilityElement()->Bool {true}
  override func accessibilityRole()->NSAccessibility.Role? {.button}
  override func accessibilityValue()->Any? {selected ? "Selected":""}
  override func accessibilityPerformPress()->Bool {
    guard isEnabled,action != nil,target != nil else{return false}
    performClick(nil);return true
  }
  override func hitTest(_ point:NSPoint)->NSView? {
    guard !isHiddenOrHasHiddenAncestor,alphaValue>0,bounds.contains(convert(point,from:superview)) else{return nil}
    return self
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas();if let tracking {removeTrackingArea(tracking)}
    let area=NSTrackingArea(rect:.zero,options:[.activeInActiveApp,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
    addTrackingArea(area);tracking=area
  }
  override func mouseEntered(with event:NSEvent){hovered=true;needsDisplay=true}
  override func mouseExited(with event:NSEvent){hovered=false;needsDisplay=true}
  override func draw(_ dirtyRect:NSRect) {
    let path=NSBezierPath(roundedRect:bounds,xRadius:7,yRadius:7)
    if isHighlighted {NSColor(Palette.line).setFill();path.fill()}
    else if selected {Palette.accentNS.withAlphaComponent(0.10).setFill();path.fill()}
    else if rowHighlighted || hovered {Palette.surfaceNS.setFill();path.fill()}
    if rowHighlighted {Palette.accentNS.withAlphaComponent(0.5).setStroke();path.lineWidth=1;path.stroke()}
    if window?.firstResponder === self {NSColor.keyboardFocusIndicatorColor.setStroke();path.lineWidth=2;path.stroke()}
    let foreground=selected ? Palette.accentNS:NSColor(Palette.ink),secondary=Palette.secondaryNS
    NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
    if !isEnabled {NSGraphicsContext.current?.cgContext.setAlpha(0.4)}
    drawSymbol(symbol,color:foreground,size:13,in:.init(x:8,y:13,width:18,height:14))
    let statuses=Array(statusSymbols.prefix(4)),textWidth=max(0,bounds.width-42-CGFloat(statuses.count)*16)
    drawText(rowTitle,font:.systemFont(ofSize:11,weight:selected ? .medium:.regular),color:NSColor(Palette.ink),in:.init(x:34,y:6,width:textWidth,height:14))
    drawText(subtitle,font:.systemFont(ofSize:9),color:secondary,in:.init(x:34,y:22,width:textWidth,height:12))
    for (offset,status) in statuses.enumerated() {
      drawSymbol(status,color:secondary,size:10,in:.init(x:bounds.maxX-8-CGFloat(statuses.count-offset)*16,y:14,width:12,height:12))
    }
  }
  private func drawText(_ text:String,font:NSFont,color:NSColor,in rect:CGRect) {
    let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(in:rect,withAttributes:[.font:font,.foregroundColor:color,.paragraphStyle:paragraph])
  }
  private func drawSymbol(_ name:String,color:NSColor,size:CGFloat,in rect:CGRect) {
    let key="\(name):\(size)"
    let image:NSImage
    if let cached=symbols[key],cached.0==color {image=cached.1}
    else {
      guard let original=(NSImage(systemSymbolName:name,accessibilityDescription:nil) ?? NSImage(systemSymbolName:"cube.transparent",accessibilityDescription:nil))?.withSymbolConfiguration(.init(pointSize:size,weight:.regular)) else{return}
      image=NSImage(size:.init(width:16,height:16),flipped:false){bounds in
        original.draw(in:bounds);color.setFill();bounds.fill(using:.sourceIn);return true
      }
      image.isTemplate=false
      if symbols.count>=8 {symbols.removeAll(keepingCapacity:true)}
      symbols[key]=(color,image)
    }
    image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
  }
}
