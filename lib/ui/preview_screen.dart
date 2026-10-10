import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../state/app_state.dart';
import 'design.dart';

/// A web page served on the host, open on the phone through a tunnel over
/// the SSH connection: what an agent started, to look at and use.
class PreviewScreen extends StatefulWidget {
  final AppState state;

  /// The page as the host knows it: `http://localhost:8787/app.html`.
  final Uri url;

  const PreviewScreen({super.key, required this.state, required this.url});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late final WebViewController _web;
  Uri? _local;
  String? _failed;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
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
    final local = await widget.state.openHostUrl(widget.url);
    if (!mounted) return;
    if (local == null) {
      setState(() => _failed = 'Not a page on the host.');
      return;
    }
    setState(() => _local = local);
    await _web.loadRequest(local);
  }

  Future<void> _external() async {
    final local = _local;
    if (local == null) return;
    // The tunnel is the phone's; Chrome reaches it while Shepherd holds the
    // connection.
    final current = await _web.currentUrl();
    await launchUrl(Uri.parse(current ?? local.toString()),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final pad = MediaQuery.of(context).size.width < 340 ? 12.0 : 16.0;
    final where = '${widget.url.host}:${widget.url.hasPort ? widget.url.port : 80}'
        '${widget.url.path}';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        // Back goes back in the page first, as a browser does.
        if (await _web.canGoBack()) {
          await _web.goBack();
        } else {
          navigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: d.ground,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.fromLTRB(pad, 10, 4, 10),
                decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: d.divider, width: 2)),
                ),
                child: Row(children: [
                  InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Icon(Icons.arrow_back, size: 18, color: d.ink2),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ON THE HOST',
                            style:
                                d.meta.copyWith(fontSize: 10, color: d.ink3)),
                        Text(where,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: d.meta.copyWith(fontSize: 13, color: d.ink)),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('preview-reload'),
                    tooltip: 'Reload',
                    icon: Icon(Icons.refresh, color: d.ink2),
                    onPressed: () => _web.reload(),
                  ),
                  IconButton(
                    key: const ValueKey('preview-external'),
                    tooltip: 'Open in the browser',
                    icon: Icon(Icons.open_in_new, color: d.ink2),
                    onPressed: _external,
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
                        padding: EdgeInsets.all(pad),
                        child: Text(
                          'Nothing came back from port '
                          '${widget.url.hasPort ? widget.url.port : 80} on the '
                          'host. Is the server running?\n\n$_failed',
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
      ),
    );
  }
}
