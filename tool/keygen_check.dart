// Verify generated identities are accepted by real OpenSSH and by dartssh2.
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:shepherd/ssh/keygen.dart';

void main(List<String> args) async {
  final id = await generateSshIdentity(comment: 'shepherd-keygen-test');
  final dir = Directory.systemTemp.createTempSync('shepherd_key');
  final keyFile = File('${dir.path}/id_ed25519');
  keyFile.writeAsStringSync(id.privateKeyPem);
  Process.runSync('chmod', ['600', keyFile.path]);
  print('KEYFILE ${keyFile.path}');
  print('PUBLIC ${id.publicKeyLine}');

  // dartssh2 must be able to parse what we wrote.
  final parsed = SSHKeyPair.fromPem(id.privateKeyPem);
  print('DARTSSH2 parsed ${parsed.length} keypair(s), type=${parsed.first.type}');

  if (args.isNotEmpty && args[0] == 'connect') {
    final socket = await SSHSocket.connect('localhost', 22,
        timeout: const Duration(seconds: 10));
    final ssh = SSHClient(socket, username: args[1], identities: parsed);
    await ssh.authenticated;
    print('DARTSSH2 AUTH OK with generated key');
    ssh.close();
  }
  exit(0);
}
