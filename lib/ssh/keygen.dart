import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A generated SSH identity: an OpenSSH-format private key to authenticate
/// with, and the one-line public key to paste into a host's authorized_keys.
class SshIdentity {
  final String privateKeyPem;
  final String publicKeyLine;

  const SshIdentity({required this.privateKeyPem, required this.publicKeyLine});
}

/// Generates an ed25519 identity and encodes it the way OpenSSH does.
///
/// Written out by hand because dartssh2 can read keys but not create them,
/// and pointycastle has no ed25519.
Future<SshIdentity> generateSshIdentity({String comment = 'shepherd'}) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final seed = await keyPair.extractPrivateKeyBytes();
  final pub = Uint8List.fromList(publicKey.bytes);

  // OpenSSH stores the private half as seed || public.
  final priv = Uint8List(64)
    ..setRange(0, 32, seed)
    ..setRange(32, 64, pub);

  final keyType = utf8.encode('ssh-ed25519');
  final publicBlob = (_Writer()..addBytes(keyType)..addBytes(pub)).take();

  final publicLine =
      'ssh-ed25519 ${base64.encode(publicBlob)} $comment';

  // The private section is checkint-prefixed, then padded to the cipher block
  // size (8 for "none") with 1,2,3… so the length is unambiguous.
  const checkInt = 0x53485044; // arbitrary; both copies must match
  final privateSection = _Writer()
    ..addUint32(checkInt)
    ..addUint32(checkInt)
    ..addBytes(keyType)
    ..addBytes(pub)
    ..addBytes(priv)
    ..addBytes(utf8.encode(comment));
  final body = privateSection.take();
  final padded = BytesBuilder()..add(body);
  for (var i = 1; padded.length % 8 != 0; i++) {
    padded.addByte(i);
  }

  final container = _Writer()
    ..addRaw(utf8.encode('openssh-key-v1'))
    ..addRaw(Uint8List.fromList([0]))
    ..addBytes(utf8.encode('none')) // ciphername
    ..addBytes(utf8.encode('none')) // kdfname
    ..addBytes(Uint8List(0)) // kdfoptions
    ..addUint32(1) // key count
    ..addBytes(publicBlob)
    ..addBytes(padded.toBytes());

  return SshIdentity(
    privateKeyPem: _pem(container.take()),
    publicKeyLine: publicLine,
  );
}

String _pem(Uint8List der) {
  final b64 = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 70) {
    lines.add(b64.substring(i, i + 70 > b64.length ? b64.length : i + 70));
  }
  return '-----BEGIN OPENSSH PRIVATE KEY-----\n'
      '${lines.join('\n')}\n'
      '-----END OPENSSH PRIVATE KEY-----\n';
}

/// SSH wire encoding: big-endian uint32 lengths in front of each blob.
class _Writer {
  final _out = BytesBuilder();

  void addUint32(int value) {
    final b = Uint8List(4)..buffer.asByteData().setUint32(0, value);
    _out.add(b);
  }

  void addRaw(List<int> bytes) => _out.add(bytes);

  void addBytes(List<int> bytes) {
    addUint32(bytes.length);
    _out.add(bytes);
  }

  Uint8List take() => _out.toBytes();
}
