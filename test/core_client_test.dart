import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/herdr/core_client.dart';

/// How herdr-core's terminals and the app's layout read as a host: spaces
/// are workspaces, terminals are panes, and the agent says its own state.
void main() {
  // Shaped as herdr-core 0.1.18 reports them.
  Map<String, dynamic> terminal(
    String address, {
    required String space,
    required String tab,
    required String where,
    Map<String, dynamic>? status,
    List<String> foreground = const ['claude'],
    int pid = 100,
    String cwd = '/home/me/work/ledger',
    String state = 'live',
    int statusMs = 0,
  }) =>
      {
        'address': address,
        'argv': ['/bin/zsh', '-l'],
        'cwd': '/home/me',
        'foreground': {
          'argv': foreground,
          'cwd': cwd,
          'name': foreground.first,
          'pid': pid,
        },
        'labels': {
          'herdr.space': space,
          'herdr.tab': tab,
          'where': where,
        },
        'state': state,
        'status': status,
        'status_ms': statusMs,
        'title': 'Reconcile March',
      };

  final layout = {
    'spaces': [
      {
        'id': 'sp1',
        'name': '',
        'folder': '/home/me',
        'tabs': [
          {'id': 'tb1', 'name': ''},
        ],
      },
      {
        'id': 'sp2',
        'name': 'Ledger',
        'folder': '/home/me/work/ledger',
        'tabs': [
          {'id': 'tb2', 'name': ''},
          {'id': 'tb3', 'name': 'prints'},
        ],
      },
    ],
  };

  test('a space is a workspace and a terminal is a pane, in the app\'s order',
      () {
    final host = CoreClient.hostState([
      terminal('t6',
          space: 'sp2',
          tab: 'tb2',
          where: 'Ledger / 1',
          status: {'app': 'claude-code', 'state': 'working'}),
      terminal('t1',
          space: 'sp1',
          tab: 'tb1',
          where: 'shepherd / 1',
          status: {'app': 'claude-code', 'state': 'idle'},
          cwd: '/home/me/work/shepherd'),
    ], layout, const {});
    expect(host.workspaces.map((w) => w.label), ['shepherd', 'Ledger']);
    final ledger = host.paneById('t6')!;
    expect(ledger.workspaceId, 'sp2');
    expect(ledger.tabId, 'tb2');
    expect(ledger.agent, 'claude');
    expect(ledger.agentStatus, 'working');
    expect(ledger.cwd, '/home/me/work/ledger');
  });

  test('the name you gave is the pane\'s: the tab\'s, else the space\'s', () {
    final host = CoreClient.hostState([
      terminal('t6', space: 'sp2', tab: 'tb2', where: 'Ledger / 1'),
      terminal('t7', space: 'sp2', tab: 'tb3', where: 'Ledger / prints'),
      terminal('t1', space: 'sp1', tab: 'tb1', where: 'shepherd / 1'),
    ], layout, const {});
    expect(host.paneById('t6')!.label, 'Ledger');
    expect(host.paneById('t7')!.label, 'prints');
    // A space nobody named is called after its folder; that is not a name.
    expect(host.paneById('t1')!.label, isNull);
  });

  test('Claude\'s session and the name you gave it come from its own file',
      () {
    final host = CoreClient.hostState([
      terminal('t1',
          space: 'sp1',
          tab: 'tb1',
          where: 'shepherd / 1',
          pid: 4242,
          status: {'app': 'claude-code', 'state': 'working'}),
    ], layout, {
      4242: {
        'pid': 4242,
        'sessionId': '5f1c2e7a-0000-4000-8000-000000000001',
        'name': 'Shepherd',
        'nameSource': 'user',
      },
    });
    final pane = host.paneById('t1')!;
    expect(pane.agentSession?.value, '5f1c2e7a-0000-4000-8000-000000000001');
    expect(pane.agentSession?.kind, 'id');
    expect(pane.label, 'Shepherd');
  });

  test('a shell is a pane but not an agent', () {
    final host = CoreClient.hostState([
      terminal('t2',
          space: 'sp1', tab: 'tb1', where: 'shepherd / 1', foreground: ['zsh']),
    ], layout, const {});
    expect(host.panes.single.agent, isNull);
    expect(host.agentPanes, isEmpty);
  });

  test('a finished terminal is gone', () {
    final host = CoreClient.hostState([
      terminal('t3',
          space: 'sp1', tab: 'tb1', where: 'shepherd / 1', state: 'finished'),
    ], layout, const {});
    expect(host.panes, isEmpty);
  });

  test('a terminal the app does not show still has a place of its own', () {
    final host = CoreClient.hostState([
      {
        'address': 't9',
        'cwd': '/home/me',
        'labels': <String, dynamic>{},
        'state': 'live',
        'foreground': {
          'argv': ['codex'],
          'cwd': '/home/me/work/x',
          'pid': 9,
        },
      },
    ], layout, const {});
    final pane = host.panes.single;
    expect(pane.agent, 'codex');
    expect(pane.agentStatus, 'unknown');
    expect(host.workspaces.single.workspaceId, pane.workspaceId);
  });

  group('the agent\'s own word for its state', () {
    test('as it says it, with an error read as wanting a look', () {
      for (final (state, shown) in [
        ('idle', 'idle'),
        ('working', 'working'),
        ('blocked', 'blocked'),
        ('done', 'done'),
        ('error', 'done'),
      ]) {
        expect(
            CoreClient.statusOf({
              'status': {'state': state}
            }),
            shown);
      }
      expect(CoreClient.statusOf({'status': null}), 'unknown');
    });

    test('the agent is named as the app names it', () {
      expect(
          CoreClient.agentOf({
            'status': {'app': 'claude-code', 'state': 'idle'}
          }),
          'claude');
      expect(
          CoreClient.agentOf({
            'foreground': {
              'argv': ['/usr/local/bin/codex']
            }
          }),
          'codex');
      expect(
          CoreClient.agentOf({
            'foreground': {
              'argv': ['vim']
            }
          }),
          isNull);
    });
  });
}
