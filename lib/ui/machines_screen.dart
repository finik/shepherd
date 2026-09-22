import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../ssh/keygen.dart';
import '../state/app_state.dart';
import '../state/machines.dart';
import 'design.dart';

/// Saved SSH hosts. Setup, visited a few times ever — so it lives behind a
/// footer link rather than competing with Sessions.
class MachinesScreen extends StatefulWidget {
  final AppState state;

  const MachinesScreen({super.key, required this.state});

  @override
  State<MachinesScreen> createState() => _MachinesScreenState();
}

class _MachinesScreenState extends State<MachinesScreen> {
  final _store = MachineStore();
  List<Machine> _machines = [];
  String? _activeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Connection state changes while this screen is open — without listening
    // the ONLINE/OFFLINE marker freezes at whatever it was on first build.
    widget.state.addListener(_onState);
    _load();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final machines = await _store.list();
    final active = await _store.activeId();
    if (!mounted) return;
    setState(() {
      _machines = machines;
      _activeId = active;
      _loading = false;
    });
  }

  Future<void> _open(Machine? machine) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => MachineEditor(machine: machine, state: widget.state),
    ));
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final pad = MediaQuery.of(context).size.width < 340 ? 12.0 : 16.0;
    final online = _machines.where((m) =>
        m.id == _activeId && widget.state.conn == ConnState.connected).length;
    return Scaffold(
      backgroundColor: d.ground,
      body: SafeArea(
        child: Column(
          children: [
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
                decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: d.divider, width: 2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.arrow_back, size: 15, color: d.ink3),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${_machines.length} HOST${_machines.length == 1 ? '' : 'S'} · $online ONLINE',
                          style: d.meta.copyWith(fontSize: 11, color: d.ink3),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text('Machines', style: d.screenTitle),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const SizedBox.shrink()
                  : _machines.isEmpty
                      ? Padding(
                          padding: EdgeInsets.symmetric(horizontal: pad),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('NO MACHINE',
                                  style: d.label.copyWith(color: d.ink)),
                              const SizedBox(height: 10),
                              Text('Add the host that runs Herdr.',
                                  style: d.prose.copyWith(color: d.ink2)),
                            ],
                          ),
                        )
                      : ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            for (final m in _machines)
                              _machineRow(d, m, pad),
                          ],
                        ),
            ),
            if (widget.state.updateBuild != null) _updateRow(d, pad),
            Padding(
              padding: EdgeInsets.fromLTRB(pad, 8, pad, 12),
              child: SizedBox(
                height: 48,
                width: double.infinity,
                child: Material(
                  color: d.ink,
                  child: InkWell(
                    onTap: () => _open(null),
                    child: Center(
                      child: Text('ADD MACHINE',
                          style: d.label
                              .copyWith(fontSize: 13, color: d.ground)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A new build published on the host. Updating over the connection the app
  /// already has beats plugging the phone in.
  Widget _updateRow(D d, double pad) {
    final state = widget.state;
    final progress = state.updateProgress;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: Material(
          color: Colors.transparent,
          shape: Border.all(color: d.accentField, width: 2),
          child: InkWell(
            onTap: state.updating
                ? null
                : () async {
                    final result = await state.installUpdate();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(result)));
                  },
            child: Stack(
              children: [
                if (state.updating)
                  FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(
                        color: d.accentField.withValues(alpha: 0.18)),
                  ),
                Center(
                  child: Text(
                    state.updating
                        ? state.updateLabel
                        : 'UPDATE TO BUILD ${state.updateBuild}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: d.label
                        .copyWith(fontSize: 12, color: d.accentText),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Hosts reuse the agent row's shape: marker column, two lines, one target.
  Widget _machineRow(D d, Machine m, double pad) {
    final active = m.id == _activeId;
    final online = active && widget.state.conn == ConnState.connected;
    return InkWell(
      onTap: () => _open(m),
      child: Padding(
        padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              height: 24,
              child: Align(
                alignment: Alignment.centerLeft,
                child: online
                    ? Container(width: 12, height: 12, color: d.ink)
                    : Container(width: 12, height: 2, color: d.ink3),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: online ? d.rowTitle : d.rowTitleQuiet),
                  const SizedBox(height: 3),
                  Text('${m.user}@${m.host}:${m.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: d.meta.copyWith(
                          fontSize: 11,
                          color: d.ink3,
                          letterSpacing: 0)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text(online ? 'ONLINE' : 'OFFLINE',
                  style: d.label.copyWith(color: d.ink3)),
            ),
          ],
        ),
      ),
    );
  }
}

class MachineEditor extends StatefulWidget {
  final Machine? machine;
  final AppState state;

  const MachineEditor({super.key, this.machine, required this.state});

  @override
  State<MachineEditor> createState() => _MachineEditorState();
}

class _MachineEditorState extends State<MachineEditor> {
  final _store = MachineStore();
  final _label = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _session = TextEditingController();
  final _password = TextEditingController();

  late String _id;
  bool _useKey = true;
  String? _publicKey;
  bool _generating = false;
  String _testResult = 'NOT TESTED YET';
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final m = widget.machine;
    _id = m?.id ??
        'm${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    if (m != null) {
      _label.text = m.label;
      _host.text = m.host;
      _port.text = m.port.toString();
      _user.text = m.user;
      _session.text = m.session;
      _useKey = m.useKey;
      _loadSecrets();
    }
  }

  Future<void> _loadSecrets() async {
    final pub = await _store.publicKey(_id);
    final pw = await _store.password(_id);
    if (!mounted) return;
    setState(() {
      _publicKey = (pub?.isEmpty ?? true) ? null : pub;
      _password.text = pw ?? '';
    });
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    final label = _label.text.trim();
    final identity = await generateSshIdentity(
        comment: label.isEmpty ? 'shepherd' : 'shepherd-$label');
    await _store.setIdentity(_id, identity.privateKeyPem, identity.publicKeyLine);
    if (!mounted) return;
    setState(() {
      _publicKey = identity.publicKeyLine;
      _generating = false;
    });
  }

  Machine _draft() => Machine(
        id: _id,
        label: _label.text.trim(),
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 22,
        user: _user.text.trim(),
        useKey: _useKey,
        session: _session.text.trim(),
      );

  /// Answering "did the key actually land on the host?" here saves a trip back
  /// to Sessions to find out.
  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = 'TESTING…';
    });
    final key = _useKey ? await _store.privateKey(_id) : null;
    final result = await widget.state
        .testConnection(_draft(), privateKeyPem: key, password: _password.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  Future<void> _save({bool connect = false}) async {
    final navigator = Navigator.of(context);
    final machine = _draft();
    await _store.save(machine);
    if (!_useKey) await _store.setPassword(_id, _password.text);
    if (connect) {
      await _store.setActive(_id);
      final key = _useKey ? await _store.privateKey(_id) : null;
      final pw = _useKey ? null : _password.text;
      if (!mounted) return;
      navigator.pop(true);
      widget.state.connect(machine, privateKeyPem: key, password: pw);
      return;
    }
    if (!mounted) return;
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final d = D.of(context);
    final pad = MediaQuery.of(context).size.width < 340 ? 12.0 : 16.0;
    return Scaffold(
      backgroundColor: d.ground,
      body: SafeArea(
        child: Column(
          children: [
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
                decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: d.divider, width: 2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.arrow_back, size: 15, color: d.ink3),
                      const SizedBox(width: 6),
                      Text('MACHINE', style: d.label.copyWith(color: d.ink3)),
                    ]),
                    const SizedBox(height: 6),
                    Text(widget.machine == null ? 'Add machine' : 'Machine',
                        style: d.screenTitle),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(pad, 16, pad, 24),
                children: [
                  _field(d, 'LABEL', _label, hint: 'Optional'),
                  _field(d, 'HOST', _host, hint: '10.0.2.2'),
                  Row(children: [
                    Expanded(child: _field(d, 'USER', _user)),
                    const SizedBox(width: 12),
                    SizedBox(
                        width: 80,
                        child: _field(d, 'PORT', _port,
                            keyboard: TextInputType.number)),
                  ]),
                  // Herdr can run several independent sessions on one host
                  // (`herdr --session work`); each has its own socket and its
                  // own agents. Empty is the one `herdr` starts by default.
                  _field(d, 'HERDR SESSION', _session, hint: 'default'),
                  const SizedBox(height: 8),
                  Text('AUTHENTICATION', style: d.label),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: _segment(d, 'SSH KEY', _useKey,
                          () => setState(() => _useKey = true)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _segment(d, 'PASSWORD', !_useKey,
                          () => setState(() => _useKey = false)),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  if (_useKey) _keySection(d) else _field(d, 'PASSWORD', _password, obscure: true),
                  const SizedBox(height: 20),
                  _button(d, _testing ? 'TESTING…' : 'TEST CONNECTION',
                      _testing ? null : _test, outlined: true),
                  const SizedBox(height: 6),
                  Text('LAST TEST · $_testResult',
                      style: d.label.copyWith(
                          color: _testResult.startsWith('OK')
                              ? d.ink2
                              : (_testResult.startsWith('FAILED')
                                  ? d.accentText
                                  : d.ink3))),
                  const SizedBox(height: 20),
                  _button(d, 'SAVE & CONNECT', () => _save(connect: true)),
                  const SizedBox(height: 8),
                  _button(d, 'SAVE', () => _save(), outlined: true),
                  if (widget.machine != null) ...[
                    const SizedBox(height: 8),
                    _button(d, 'DELETE', () async {
                      final navigator = Navigator.of(context);
                      await _store.delete(_id);
                      if (!mounted) return;
                      navigator.pop(true);
                    }, danger: true),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _keySection(D d) {
    if (_publicKey == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Shepherd creates its own key for this machine. The private half '
            'stays in this phone\'s keystore — only the public line leaves.',
            style: d.prose.copyWith(fontSize: 14, color: d.ink2),
          ),
          const SizedBox(height: 12),
          _button(d, _generating ? 'GENERATING…' : 'GENERATE SSH KEY',
              _generating ? null : _generate, outlined: true),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SHEPHERD PUBLIC KEY', style: d.label),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          color: d.fill,
          padding: const EdgeInsets.all(10),
          child: SelectableText(_publicKey!,
              style: d.codeBlock.copyWith(color: d.ink2)),
        ),
        const SizedBox(height: 6),
        Text('Append it to ~/.ssh/authorized_keys on the host.',
            style: d.prose.copyWith(fontSize: 13, color: d.ink3)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: _button(d, 'SHARE', () {
              SharePlus.instance.share(ShareParams(
                  text: _publicKey!, subject: 'Shepherd public key'));
            }, outlined: true),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _button(d, 'COPY', () async {
              await Clipboard.setData(ClipboardData(text: _publicKey!));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Public key copied')));
            }, outlined: true),
          ),
        ]),
      ],
    );
  }

  Widget _segment(D d, String label, bool selected, VoidCallback onTap) =>
      SizedBox(
        height: 44,
        child: Material(
          color: selected ? d.ink : Colors.transparent,
          shape: selected ? null : Border.all(color: d.divider, width: 2),
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: Text(label,
                  style: d.label
                      .copyWith(color: selected ? d.ground : d.ink2)),
            ),
          ),
        ),
      );

  Widget _button(D d, String label, VoidCallback? onTap,
          {bool outlined = false, bool danger = false}) =>
      SizedBox(
        height: 48,
        width: double.infinity,
        child: Material(
          color: outlined || danger ? Colors.transparent : d.ink,
          shape: outlined || danger
              ? Border.all(
                  color: danger ? d.accentField : d.divider, width: 2)
              : null,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: Text(label,
                  style: d.label.copyWith(
                    fontSize: 13,
                    color: danger
                        ? d.accentText
                        : (outlined ? d.ink : d.ground),
                  )),
            ),
          ),
        ),
      );

  Widget _field(D d, String label, TextEditingController controller,
          {String? hint, bool obscure = false, TextInputType? keyboard}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: d.label),
            TextField(
              controller: controller,
              obscureText: obscure,
              keyboardType: keyboard,
              style: TextStyle(
                  fontFamily: D.mono, fontSize: 15, color: d.ink),
              cursorColor: d.accentField,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                    fontFamily: D.mono, fontSize: 15, color: d.ink3),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: d.divider, width: 2)),
                focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: d.ink, width: 2)),
              ),
            ),
          ],
        ),
      );
}
