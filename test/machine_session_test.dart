import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/machines.dart';

/// Herdr runs named sessions side by side (`herdr --session work`), each a
/// server with its own socket.
void main() {
  Machine machine(String session) =>
      Machine(id: 'm', label: 'm', host: 'h', user: 'u', session: session);

  test('no session is the default socket', () {
    expect(machine('').socketSuffix, '.config/herdr/herdr.sock');
    expect(machine('default').socketSuffix, '.config/herdr/herdr.sock');
  });

  test('a named session has its own socket', () {
    expect(machine('work').socketSuffix,
        '.config/herdr/sessions/work/herdr.sock');
  });

  test('a name that could climb out of the directory is ignored', () {
    expect(machine('../../etc').socketSuffix, '.config/herdr/herdr.sock');
    expect(machine('a/b').socketSuffix, '.config/herdr/herdr.sock');
    expect(machine('.hidden').socketSuffix, '.config/herdr/herdr.sock');
  });

  test('the session survives being saved and loaded', () {
    final back = Machine.fromJson(machine('work').toJson());
    expect(back.session, 'work');
    // A machine saved without a session is the default one.
    final old = Machine.fromJson(
        {'id': 'm', 'label': 'm', 'host': 'h', 'user': 'u'});
    expect(old.session, '');
  });
}
