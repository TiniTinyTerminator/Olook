import QtQuick
import qs.Commons

// Wheel scrolling that glides instead of stepping.
//
// Declared inside a Flickable or ListView, which is where it attaches:
//
//     Flickable {
//       id: view
//       SmoothScroll { view: view }
//     }
//
// A touchpad already streams fine-grained pixel deltas, and animating those
// fights the gesture — the content would lag behind the fingers — so only
// wheel clicks, which arrive as coarse angle deltas, are animated. Everything
// else is handed straight back to the Flickable.
WheelHandler {
  id: handler

  // The view to scroll. Named `view` because WheelHandler already has a
  // `target`, which is the thing it would manipulate on its own; we drive the
  // animation instead, so that stays null.
  property Flickable view: null

  // One wheel click's worth of travel, and how long it takes to get there.
  property real step: Style.space(110)
  property int duration: 180

  target: null
  acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

  readonly property real limit: view ? Math.max(0, view.contentHeight - view.height) : 0
  property real goal: 0

  // Anything that moves the view itself — a keyboard selection scrolling a row
  // into sight, a drag — should call this first, or the glide finishes and
  // yanks the content back to where the wheel was heading.
  function cancel() { glide.stop() }

  function scrollBy(delta) {
    if (!handler.view || handler.limit <= 0) return
    // Chain onto a glide already in flight rather than restarting from where
    // the content happens to be, so a fast series of clicks accumulates.
    var from = glide.running ? handler.goal : handler.view.contentY
    handler.goal = Math.max(0, Math.min(handler.limit, from + delta))
    glide.restart()
  }

  property NumberAnimation glide: NumberAnimation {
    id: glide
    target: handler.view
    property: "contentY"
    to: handler.goal
    duration: handler.duration
    easing.type: Easing.OutCubic
  }

  onWheel: function (event) {
    var byPixel = event.pixelDelta.y !== 0
    if (!handler.view || byPixel || event.angleDelta.y === 0) {
      // Touchpads, horizontal wheels, and the case where we have nothing to
      // scroll: leave it to the Flickable.
      event.accepted = false
      return
    }
    handler.scrollBy(-event.angleDelta.y / 120 * handler.step)
    event.accepted = true
  }
}
