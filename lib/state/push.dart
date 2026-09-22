import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Registers this device for push and tells the host where to reach it.
///
/// The watcher in [Watch] only runs while the app is alive and Android is
/// feeling generous. Push is the other half: Herdr's own plugin sends when an
/// agent stops, so a notification arrives with the app closed, after a reboot,
/// and through Doze — at no battery cost, because the phone is not asking
/// anything.
///
/// The token goes to the host as a file under `~/.shepherd/push-tokens/`, one
/// per device, over the SSH connection the app already holds. Nothing else is
/// needed on either side: the plugin sends to every token it finds and deletes
/// the ones Google reports as dead.
class Push {
  static bool _started = false;

  /// Whether the app was built with Firebase configured. Without
  /// google-services.json the plugin cannot initialise, and saying so is
  /// better than a crash at startup.
  static bool get available => Firebase.apps.isNotEmpty;

  static Future<void> start() async {
    if (_started) return;
    try {
      await Firebase.initializeApp();
      _started = true;
    } catch (e) {
      debugPrint('push unavailable: $e');
    }
  }

  /// The token for this device, or null when push is not set up or the user
  /// refused notifications.
  static Future<String?> token() async {
    if (!_started) return null;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        return null;
      }
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('push token failed: $e');
      return null;
    }
  }

  /// Write the token where the Herdr plugin looks for it.
  ///
  /// Keyed by a stable id per install, so reinstalling replaces its own file
  /// rather than leaving a dead token behind for the plugin to discover.
  /// Returns whether this device is now reachable by push.
  static Future<bool> register(SSHClient ssh, String deviceId) async {
    final value = await token();
    if (value == null) return false;
    final safeId = deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    try {
      await ssh.run(
        'mkdir -p ~/.shepherd/push-tokens && '
        "printf '%s' ${_quote(value)} > ~/.shepherd/push-tokens/${_quote(safeId)}",
      );
      return true;
    } catch (e) {
      debugPrint('push registration failed: $e');
      return false;
    }
  }

  /// Stop this device receiving push: drop the token here and on the host.
  static Future<void> unregister(SSHClient ssh, String deviceId) async {
    final safeId = deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    try {
      await ssh.run('rm -f ~/.shepherd/push-tokens/${_quote(safeId)}');
      if (_started) await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('push unregistration failed: $e');
    }
  }

  /// Say that you are using the phone right now.
  ///
  /// The host cannot see this any other way, and someone reading a reply in
  /// the app does not need it repeated as a notification. Throttled, because
  /// the only thing that matters is the minute it happened in.
  static DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> touch(SSHClient ssh, String deviceId) async {
    final now = DateTime.now();
    if (now.difference(_lastTouch) < const Duration(seconds: 60)) return;
    _lastTouch = now;
    final safeId = deviceId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    try {
      await ssh.run('mkdir -p ~/.shepherd/active && '
          'touch ~/.shepherd/active/${_quote(safeId)}');
    } catch (_) {
      // Missing a heartbeat only costs a notification you did not need.
    }
  }

  /// Tell the host plugin how recent counts as "still at the computer".
  ///
  /// Written as a file beside the plugin's own config rather than into it, so
  /// the app can own this setting without rewriting the credential path the
  /// plugin reads next to it.
  static Future<void> setQuietMinutes(SSHClient ssh, int minutes) async {
    try {
      await ssh.run(
        'd=~/.config/herdr/plugins/config/shepherd.push; '
        'mkdir -p "\$d" && printf %s $minutes > "\$d/suppress-minutes"',
      );
    } catch (e) {
      debugPrint('quiet-minutes write failed: $e');
    }
  }

  static String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}

/// A stable identifier for this install, for naming the token file.
String deviceIdFrom(String androidId) =>
    androidId.isNotEmpty ? androidId : Platform.localHostname;
