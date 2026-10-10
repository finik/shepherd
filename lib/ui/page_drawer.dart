import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/app_state.dart';
import 'design.dart';

/// A web page served on the host, kept open beside the rest of the app.
///
/// It sits over every screen and stays loaded when it is put away: slid off
/// to the right, it leaves a small lip on the screen's edge, and pulling or
/// tapping the lip brings it back as it was. Back goes back in the page, then
/// puts it away; only the close button closes it.
class PageDrawer extends StatefulWidget {
  final AppState state;
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  const PageDrawer(
      {super.key,
      required this.state,
      required this.navigator,
      required this.child});

  @override
  State<PageDrawer> createState() => _PageDrawerState();
}

class _PageDrawerState extends State<PageDrawer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220));
  final _page = GlobalKey<_PagePanelState>();

  /// While the page is out, a route sits on the navigator so that the back
  /// button reaches the page rather than the screen beneath it.
  Route<void>? _shownRoute;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.state.removeListener(_sync);
    _slide.dispose();
    super.dispose();
  }

  void _sync() {
    final shown = widget.state.pageUrl != null && widget.state.pageShown;
    if (shown && _slide.value < 1 && _slide.status != AnimationStatus.forward) {
      _slide.forward();
    } else if (!shown &&
        _slide.value > 0 &&
        _slide.status != AnimationStatus.reverse) {
      _slide.reverse();
    }
    _syncRoute(shown);
    if (mounted) setState(() {});
  }

  void _syncRoute(bool shown) {
    final navigator = widget.navigator.currentState;
    if (navigator == null) return;
    if (shown && _shownRoute == null) {
      final route = _ShownRoute(onBack: _back);
      _shownRoute = route;
      navigator.push(route).then((_) {
        if (_shownRoute == route) {
          _shownRoute = null;
          widget.state.showPage(false);
        }
      });
    } else if (!shown && _shownRoute != null) {
      final route = _shownRoute!;
      _shownRoute = null;
      if (route.isActive) navigator.removeRoute(route);
    }
  }

  Future<void> _back() async {
    if (await _page.currentState?.goBack() ?? false) return;
    widget.state.showPage(false);
  }

  void _drag(DragUpdateDetails d, double width) {
    _slide.value -= d.primaryDelta! / width;
  }

  void _release(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final out = velocity < -300 || (velocity.abs() <= 300 && _slide.value > 0.5);
    widget.state.showPage(out);
    // Settle even when the shown state did not change.
    out ? _slide.forward() : _slide.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.state.pageUrl;
    final width = MediaQuery.of(context).size.width;
    final d = D.of(context);
    return Stack(children: [
      widget.child,
      if (url != null)
        AnimatedBuilder(
          animation: _slide,
          builder: (context, panel) => Positioned(
            top: 0,
            bottom: 0,
            left: (1 - _slide.value) * width,
            width: width,
            // Always the same widgets, slid off the screen when put away, so
            // the page is never rebuilt and keeps where it was.
            // No shadow while away: it would fall on the screen's edge.
            child: Material(
                elevation: _slide.value == 0 ? 0 : 12, child: panel),
          ),
          child: Stack(children: [
            _PagePanel(
              key: _page,
              state: widget.state,
              url: url,
              onHide: () => widget.state.showPage(false),
            ),
            // The left edge pulls the page back off to the right; the rest of
            // it belongs to the page's own scrolling.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 14,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (e) => _drag(e, width),
                onHorizontalDragEnd: _release,
              ),
            ),
          ]),
        ),
      if (url != null)
        AnimatedBuilder(
          animation: _slide,
          builder: (context, _) => _slide.value > 0.02
              ? const SizedBox.shrink()
              : Positioned(
                  right: 0,
                  top: MediaQuery.of(context).size.height * 0.42,
                  child: GestureDetector(
                    key: const ValueKey('page-lip'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.state.showPage(true),
                    onHorizontalDragUpdate: (e) => _drag(e, width),
                    onHorizontalDragEnd: _release,
                    child: Container(
                      width: 22,
                      height: 76,
                      decoration: BoxDecoration(
                        color: d.ink,
                        borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(10)),
                      ),
                      child: Icon(Icons.chevron_left,
                          size: 20, color: d.ground),
                    ),
                  ),
                ),
        ),
    ]);
  }
}

/// Marks the page as out, so the back button comes to it.
class _ShownRoute extends PageRoute<void> {
  final Future<void> Function() onBack;

  _ShownRoute({required this.onBack});

  @override
  bool get opaque => false;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onBack();
        },
        child: const SizedBox.shrink(),
      );
}

/// The page itself: its address, reload, the way out to the browser, and
/// the buttons that put it away or close it.
class _PagePanel extends StatefulWidget {
  final AppState state;
  final Uri url;
  final VoidCallback onHide;

  const _PagePanel(
      {super.key, required this.state, required this.url, required this.onHide});

  @override
  State<_PagePanel> createState() => _PagePanelState();
}

class _PagePanelState extends State<_PagePanel> {
  late WebViewController _web;
  Uri? _local;
  String? _failed;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PagePanel old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  void _load() {
    _local = null;
    _failed = null;
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => mounted ? setState(() => _progress = p) : null,
        onWebResourceError: (e) {
          // Only the page itself failing is worth a message; a missing
          // favicon is not.
          if (e.isForMainFrame != true || !mounted) return;
          setState(() => _failed = e.description);
        },
        onPageStarted: (_) => mounted ? setState(() => _failed = null) : null,
      ));
    _open();
  }

  Future<void> _open() async {
    final url = widget.url;
    final local = await widget.state.openHostUrl(url);
    if (!mounted || url != widget.url) return;
    if (local == null) {
      setState(() => _failed = 'Not a page on the host.');
      return;
    }
    setState(() => _local = local);
    await _web.loadRequest(local);
  }

  /// Back in the page's own history; false when there is none.
  Future<bool> goBack() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
      return true;
    }
    return false;
  }

  Future<void> _external() async {
    final local = _local;
    if (local == null) return;
    // The tunnel is the phone's; the browser reaches it while Shepherd holds
    // the connection.
    final current = await _web.currentUrl();
    await launchUrl(Uri.parse(current ?? local.toString()),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final port = widget.url.hasPort ? widget.url.port : 80;
    final where = '${widget.url.host}:$port${widget.url.path}';
    return ColoredBox(
      color: d.ground,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(4, 6, 0, 6),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: d.divider, width: 2)),
              ),
              child: Row(children: [
                IconButton(
                  key: const ValueKey('page-hide'),
                  tooltip: 'Put away',
                  icon: Icon(Icons.chevron_right, color: d.ink2),
                  onPressed: widget.onHide,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('ON THE HOST',
                          style: d.meta.copyWith(fontSize: 10, color: d.ink3)),
                      Text(where,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: d.meta.copyWith(fontSize: 13, color: d.ink)),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('page-reload'),
                  tooltip: 'Reload',
                  icon: Icon(Icons.refresh, color: d.ink2),
                  onPressed: () => _web.reload(),
                ),
                IconButton(
                  key: const ValueKey('page-external'),
                  tooltip: 'Open in the browser',
                  icon: Icon(Icons.open_in_new, color: d.ink2),
                  onPressed: _external,
                ),
                IconButton(
                  key: const ValueKey('page-close'),
                  tooltip: 'Close',
                  icon: Icon(Icons.close, color: d.ink2),
                  onPressed: widget.state.closePage,
                ),
              ]),
            ),
            if (_progress > 0 && _progress < 100)
              LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2,
                  color: d.ink2,
                  backgroundColor: d.ground),
            Expanded(
              child: _failed != null
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Nothing came back from port $port on the host. Is '
                        'the server running?\n\n$_failed',
                        style: d.prose.copyWith(color: d.ink3),
                      ),
                    )
                  : _local == null
                      ? const SizedBox.shrink()
                      : WebViewWidget(controller: _web),
            ),
          ],
        ),
      ),
    );
  }
}
