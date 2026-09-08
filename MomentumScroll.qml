import QtQuick
import qs.Commons

// Wheel scrolling that carries on after the wheel stops.
//
// Declared inside a Flickable or ListView, which is the view it scrolls:
//
//     Flickable {
//       id: view
//       MomentumScroll { view: view }
//     }
//
// A Flickable on its own jumps a fixed distance per wheel click and stops
// dead, which reads as stuttering down a long list. Handing the click to
// `flick()` instead gives the content the movement it has when you throw it
// with a finger: it keeps going after the wheel does and slows to a halt
// under the view's own `flickDeceleration`. Clicks in quick succession stack,
// so spinning the wheel builds speed rather than restarting the throw.
//
// The wheel is caught with a MouseArea rather than a WheelHandler. A handler
// declared in a Flickable never sees the event — the Flickable has already
// taken it — whereas a MouseArea over the view is offered it first. Accepting
// no buttons keeps it out of the way of everything else: clicks and hovers go
// straight through to the rows underneath.
MouseArea {
  id: root

  property Flickable view: null

  // Pixels per second one wheel click is worth. A throw of v travels
  // v²/(2·flickDeceleration), so at the default 1500 px/s² this is a little
  // over two rows of the message list per click.
  property real kick: Style.space(800)

  acceptedButtons: Qt.NoButton
  anchors.fill: parent
  // A Flickable puts its declared children inside its contentItem, which
  // scrolls away underneath us. This belongs on the view itself.
  Component.onCompleted: if (root.view) root.parent = root.view

  // The velocity last handed to flick(), and when, so the next click can work
  // out how much of that throw is still to run and add to it. Reading it back
  // off the view is no good: `verticalVelocity` is smoothed, and reports the
  // opposite sign to the one flick() takes.
  property real velocity: 0
  property double sentAt: 0

  // Anything that moves the view itself — a keyboard selection scrolling a row
  // into sight, a jump to the top — should call this first, or the throw
  // carries on afterwards and drags the content back off the row.
  function cancel() {
    root.velocity = 0
    if (root.view)
      root.view.cancelFlick()
  }

  // What is left of the throw in flight, or 0 once it has run out or the view
  // has been stopped by something else — a bound, a drag, cancel().
  function remaining() {
    if (!root.view || !root.view.flicking || root.velocity === 0)
      return 0
    var spent = root.view.flickDeceleration * (Date.now() - root.sentAt) / 1000
    var left = Math.abs(root.velocity) - spent
    if (left <= 0)
      return 0
    return root.velocity < 0 ? -left : left
  }

  function throwBy(clicks) {
    if (!root.view)
      return
    var cap = root.view.maximumFlickVelocity
    var v = root.remaining() + clicks * root.kick
    root.velocity = Math.max(-cap, Math.min(cap, v))
    root.sentAt = Date.now()
    root.view.flick(0, root.velocity)
  }

  onWheel: function (event) {
    // angleDelta is the field Qt always fills in. A touchpad adds pixelDelta
    // on top and is already smooth — throwing the content on every one of
    // those deltas would run away with it — so it keeps the Flickable's own
    // handling. flick() takes the velocity of the content, which travels
    // against the scroll, and so does the delta: a click towards you is
    // negative and sends the content up the screen.
    if (!root.view || event.angleDelta.y === 0 || event.pixelDelta.y !== 0) {
      event.accepted = false
      return
    }
    root.throwBy(event.angleDelta.y / 120)
    event.accepted = true
  }
}
