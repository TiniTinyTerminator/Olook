import QtQuick
import QtWebEngine

// The reading pane's HTML renderer.
//
// Mail HTML is written for browsers: stylesheets, classes, table layout, and
// increasingly flexbox. Qt's rich text renders a subset of HTML 4 and drops
// all of it, so a newsletter arrives as a stack of unstyled divs. This is a
// real engine, sealed shut — no scripting, no cache, no cookies, nothing
// fetched from the network, and every link handed to the browser rather than
// followed here. The document arrives already sanitized by olook's htmldoc,
// carrying a Content-Security-Policy that forbids a second time what the
// sanitizer removed the first.
//
// The view is sized to its content and never scrolls itself: the reading
// pane's own Flickable scrolls the message, so there is one scrollbar rather
// than a page inside a page.
Item {
  id: root

  property string document: ""
  // A block of markup rather than a whole page -- a quoted original inside a
  // reply, say. Wrapped here so the caller does not have to know what a
  // document needs around it.
  property string fragment: ""
  onFragmentChanged: root.document = root.fragment === "" ? "" : (
    '<!DOCTYPE html><html><head><meta charset="utf-8">'
    + '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; '
    + 'img-src file: data:; style-src \'unsafe-inline\'">'
    + '<style>html,body{margin:0;padding:0;background:#fbfbf9;color:#16181d;'
    + 'font:14px/1.5 system-ui,sans-serif;height:auto!important}'
    + 'img{max-width:100%;height:auto}</style></head><body>'
    + root.fragment + '</body></html>')
  // Local content needs a local origin before it may load the inline images
  // the sanitizer pointed at file:// paths.
  property url baseUrl: "file:///"
  property color paper: "#fbfbf9"
  // Off unless the reader has asked for the message's remote images. The
  // document's own policy has to agree as well, so this alone opens nothing.
  property bool allowRemote: false
  // Set by reload() for the one navigation loadHtml makes; see
  // onNavigationRequested.
  property bool loadPending: false

  // A page that sizes itself to the viewport would grow every time we grew to
  // match it, so the measurement only ever climbs, and stops somewhere sane.
  readonly property real maxHeight: 24000
  property real measured: 0
  readonly property real contentHeight: Math.max(root.measured, 120)

  signal linkActivated(string link)
  // Raised for a scroll that arrived here rather than at the reading pane's
  // own handler, so the pane can act on it. See the MouseArea below.
  signal wheeled(real angleY, real pixelY)

  implicitHeight: root.contentHeight

  onDocumentChanged: root.reload()

  // Whether remote images may load is a setting on the view, and a setting
  // read at load time: changing it afterwards leaves the page as it was
  // rendered. So the page is rendered again. This is what made images vanish
  // when the reading pane went to plain text and back -- the view is rebuilt
  // from scratch on the way back, and its default is to allow nothing.
  onAllowRemoteChanged: if (root.document !== "") root.reload()

  function reload() {
    root.measured = 0
    root.fitPending = true
    view.zoomFactor = 1
    settle.ticks = 0
    settle.restart()
    root.loadPending = true
    view.loadHtml(root.document, root.baseUrl)
  }

  // Mail is written for a width of its own choosing, and a reading pane is
  // whatever width the window left it. When the message is the wider of the
  // two it gets scaled down to fit rather than running off the edge.
  //
  // Worked out once per document and then left alone. Zooming changes what
  // the page reports, so recomputing from the new measurement would be the
  // same trap the height fell into: each correction feeding the next.
  property bool fitPending: true
  readonly property real minimumScale: 0.4

  function fitWidth() {
    if (!root.fitPending || root.width <= 0)
      return
    var natural = view.contentsSize.width
    if (natural <= 0)
      return
    root.fitPending = false
    if (natural <= root.width + 1)
      return
    view.zoomFactor = Math.max(root.minimumScale, root.width / natural)
    // The page is a different height at a different scale, and the
    // measurement only ever climbs, so it starts again from here.
    root.measured = 0
    settle.ticks = 0
    settle.restart()
  }

  // contentsSize reports only when it changes. Load a second document that
  // happens to lay out to the same height as the last one -- the same message
  // with its images allowed, say -- and no signal ever arrives, so a
  // measurement waiting for one waits forever and the message collapses to
  // the minimum. Sample it directly for a few seconds after each load, and go
  // on listening afterwards for the pictures that arrive late and make the
  // page taller.
  function measure() {
    root.fitWidth()
    var height = view.contentsSize.height * view.zoomFactor
    if (height > root.measured)
      root.measured = Math.min(height, root.maxHeight)
  }

  Timer {
    id: settle
    interval: 200
    repeat: true
    property int ticks: 0
    onTriggered: {
      root.measure()
      if (++settle.ticks >= 25)
        settle.stop()
    }
  }

  WebEngineProfile {
    id: sealed
    offTheRecord: true
    httpCacheType: WebEngineProfile.NoCache
    persistentCookiesPolicy: WebEngineProfile.NoPersistentCookies
  }

  WebEngineView {
    id: view
    anchors.fill: parent
    profile: sealed
    backgroundColor: root.paper

    settings.javascriptEnabled: false
    settings.localStorageEnabled: false
    settings.localContentCanAccessRemoteUrls: root.allowRemote
    settings.localContentCanAccessFileUrls: true
    settings.errorPageEnabled: false
    settings.pdfViewerEnabled: false
    settings.autoLoadImages: true
    settings.unknownUrlSchemePolicy: WebEngineSettings.DisallowUnknownUrlSchemes
    // A file dropped on the message would otherwise be opened in its place,
    // and link targets are not looked up ahead of a click -- a DNS lookup
    // for a sender's domain says the message was opened.
    settings.navigateOnDropEnabled: false
    settings.dnsPrefetchEnabled: false
    settings.hyperlinkAuditingEnabled: false

    onContentsSizeChanged: root.measure()

    // The document itself arrives through loadHtml. Anything else is the
    // message trying to navigate, which mail does not get to do.
    onNavigationRequested: function (request) {
      var target = String(request.url)
      if (request.navigationType === WebEngineNavigationRequest.LinkClickedNavigation) {
        request.action = WebEngineNavigationRequest.IgnoreRequest
        root.linkActivated(target)
      } else if (root.loadPending && target.startsWith("data:text/html")) {
        // The document reload() just handed over, which loadHtml delivers
        // as a data: URL. Exactly one is expected per load.
        root.loadPending = false
      } else {
        // Anything else -- the web, a file on this machine, a second
        // document -- is somewhere the message is trying to take the view.
        request.action = WebEngineNavigationRequest.IgnoreRequest
      }
    }

    // A target="_blank" link asks for a window. It gets the browser instead.
    onNewWindowRequested: function (request) {
      root.linkActivated(String(request.requestedUrl))
    }
  }

  // An engine accepts every wheel event it is offered, including the ones it
  // cannot act on — this page is sized to its content and has nothing of its
  // own to scroll. So a scroll that reaches it is a scroll that disappears.
  // This sits on top and hands scrolling back out to the reading pane, which
  // is what should be moving. Clicks, hover and selection pass straight
  // through: it takes no buttons.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    onWheel: function (event) {
      root.wheeled(event.angleDelta.y, event.pixelDelta.y)
      event.accepted = true
    }
  }
}
