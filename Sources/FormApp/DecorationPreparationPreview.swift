import AppKit
import FormCore
import FormGraphics
import SwiftUI

enum DecorationPreviewMode:String,CaseIterable {case application="Application",delivery="Delivery",underbase="Underbase reference"}
struct DecorationPreparationPreview:NSViewRepresentable {
  var plan:DecorationGeometry
  var mirror:Bool
  var mode:DecorationPreviewMode
  var layer:String?
  func makeNSView(context:Context)->DecorationPreviewView {DecorationPreviewView()}
  func updateNSView(_ view:DecorationPreviewView,context:Context) {view.plan=plan;view.mirror=mirror;view.mode=mode;view.selectedMaterial=layer;view.needsDisplay=true}
}
@MainActor final class DecorationPreviewView:NSView {
  var plan:DecorationGeometry?
  var mirror=false
  var mode=DecorationPreviewMode.delivery
  var selectedMaterial:String?
  override var isFlipped:Bool {true}
  override var intrinsicContentSize:NSSize {.init(width:NSView.noIntrinsicMetric,height:NSView.noIntrinsicMetric)}
  override func draw(_ dirtyRect:NSRect) {
    guard let context=NSGraphicsContext.current?.cgContext else{return}
    NSColor(calibratedWhite:0.91,alpha:1).setFill();bounds.fill()
    guard var plan else{return}
    plan.options.mirror=mode == .application ? false:mirror
    let margin=24.0,scale=max(0.0001,min((bounds.width-margin*2)/plan.pageWidth,(bounds.height-margin*2)/plan.pageHeight))
    let size=NSSize(width:plan.pageWidth*scale,height:plan.pageHeight*scale),origin=NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2)
    let board=NSRect(origin:origin,size:size)
    context.saveGState();context.clip(to:board)
    for row in 0...Int(ceil(board.height/12)) {for col in 0...Int(ceil(board.width/12)) {
      context.setFillColor(NSColor(calibratedWhite:(row+col)%2==0 ? 0.98:0.89,alpha:1).cgColor)
      context.fill(.init(x:board.minX+Double(col)*12,y:board.minY+Double(row)*12,width:12,height:12))
    }}
    context.translateBy(x:origin.x,y:origin.y);context.scaleBy(x:scale,y:scale)
    if mode == .underbase {
      context.addPath(plan.deliveryPath(plan.silhouette));context.setFillColor(NSColor.black.cgColor);context.fillPath()
    }else {
      for region in plan.regions where selectedMaterial==nil || region.paintKey==selectedMaterial {
        context.addPath(plan.deliveryPath(region.path));context.setFillColor((selectedMaterial==nil ? FormColor.color(region.color):NSColor.black).cgColor);context.fillPath()
      }
    }
    if plan.options.process == .htv,plan.options.weedMargin>0 {context.setStrokeColor(NSColor.systemOrange.cgColor);context.setLineWidth(1/scale);context.stroke(.init(x:0,y:0,width:plan.pageWidth,height:plan.pageHeight))}
    context.restoreGState();context.setStrokeColor(NSColor(calibratedWhite:0.72,alpha:1).cgColor);context.setLineWidth(1);context.stroke(board)
  }
}
