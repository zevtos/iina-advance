//
//  ViewportView.swift
//  iina
//
//  Created by Matt Svoboda on 11/24/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Cocoa

final class ViewportView: NSView {
  unowned var player: PlayerCore!
  var log: any Logger.Subsystem { player.log }

  let topSpacer = SpacerView(id: "ViewportTopSpacer")
  let bottomSpacer = SpacerView(id: "ViewportBottomSpacer")
  let leadingSpacer = SpacerView(id: "ViewportLeadingSpacer")
  let trailingSpacer = SpacerView(id: "ViewportTrailingSpacer")

  init() {
    super.init(frame: .zero)
    idString = "ViewportView"
    registerForDraggedTypes([.nsFilenames, .nsURL, .string])
    wantsLayer = true  // needed for background color
    /// Tag overlay UI as extended sRGB so macOS' compositor maps it to SDR
    /// paper-white reference (~203 nits) when the contained `videoView` layer
    /// turns on `wantsExtendedDynamicRangeContent` for HDR. Without this, the
    /// OS falls back to device RGB heuristics and the OSC / OSD can render at
    /// full display peak luminance over EDR video.
    layer?.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
    clipsToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
    autoresizesSubviews = false
    setCCResistance(h: 250, v: 250)  // unclear if this is ever necessary, but lower it to be safe
    initVideoViewSpacers()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Need to forward this so that dragging to resize sidebar works in native full screen
  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    pwc?.mouseDown(with: event)
  }

  // Need to forward this so that dragging to resize sidebar works in native full screen
  override func mouseDragged(with event: NSEvent) {
    super.mouseDragged(with: event)
    pwc?.mouseDragged(with: event)
  }

  // Need to forward this so that dragging to resize sidebar works in native full screen
  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    pwc?.mouseUp(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    super.rightMouseDown(with: event)
    pwc?.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    pwc?.rightMouseUp(with: event)
    super.rightMouseUp(with: event)
  }

  override func pressureChange(with event: NSEvent) {
    pwc?.pressureChange(with: event)
    super.pressureChange(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    pwc?.otherMouseDown(with: event)
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    pwc?.otherMouseUp(with: event)
    super.otherMouseUp(with: event)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return player.acceptFromPasteboard(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

  // MARK: - Spacers

  func initVideoViewSpacers() {
    // Reduce the unused dimension of each spacer to keep its size well-defined
    topSpacer.widthAnchor.constraint(equalToConstant: 0).isActive = true
    bottomSpacer.widthAnchor.constraint(equalToConstant: 0).isActive = true
    leadingSpacer.heightAnchor.constraint(equalToConstant: 0).isActive = true
    trailingSpacer.heightAnchor.constraint(equalToConstant: 0).isActive = true
  }

  /// Returns true if at least one spacer needed to be added.
  func addSpacers() -> Bool {
    var spacersAdded = 0
    if !subviews.contains(topSpacer) {
      addSubview(topSpacer)
      topSpacer.addConstraintsToFillSuperview(top: 0, leading: 0)
      spacersAdded += 1
    }
    if !subviews.contains(bottomSpacer) {
      addSubview(bottomSpacer)
      bottomSpacer.addConstraintsToFillSuperview(bottom: 0, trailing: 0)
      spacersAdded += 1
    }
    if !subviews.contains(leadingSpacer) {
      addSubview(leadingSpacer)
      leadingSpacer.addConstraintsToFillSuperview(top: 0, leading: 0)
      spacersAdded += 1
    }
    if !subviews.contains(trailingSpacer) {
      addSubview(trailingSpacer)
      trailingSpacer.addConstraintsToFillSuperview(top: 0, trailing: 0)
      spacersAdded += 1
    }
    if spacersAdded > 0 {
      player.log.verbose("[Load] Added \(spacersAdded) spacers to viewportView")
      return true
    }
    return false
  }

  func removeSpacers() {
    topSpacer.removeFromSuperview()
    bottomSpacer.removeFromSuperview()
    leadingSpacer.removeFromSuperview()
    trailingSpacer.removeFromSuperview()
  }

  var viewportConstraints: ViewportConstraints? = nil

  /// Convenience property
  var videoViewAspect: CGFloat? {  viewportConstraints?.aspectRatio.multiplier }
}

extension PlayerWindowController {

  /// Need to call this after adding a new subview to `viewportView` to ensure ordering of subviews is correct.
  func sortViewportViewSubviews() {
    let possibleSubviews = [viewportView.topSpacer, viewportView.bottomSpacer, viewportView.leadingSpacer, viewportView.trailingSpacer,
                            pip.overlayView,
                            videoView,
                            pluginOverlayViewContainer,
                            defaultAlbumArtView,
                            osd.additionalInfoView,
                            bufferIndicatorView,
                            controlBarFloating.view,
                            osd.osdView]
    let correctOrderedSubviews = possibleSubviews.filter { $0 != nil && viewportView.containsSubview($0!) }
    for subview in correctOrderedSubviews {
      guard let subview else { continue }
      viewportView.addSubview(subview, positioned: .above, relativeTo: nil)
    }
  }

}
