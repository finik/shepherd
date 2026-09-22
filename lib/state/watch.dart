import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'watcher.dart';

/// Starting and stopping the background watcher, from the UI isolate.
class Watch {
  /// How often the service asks the host what changed. Three seconds is right
  /// for a screen you are looking at; off screen it is a battery bill for
  /// news that can wait ten.
  static const _interval = 10000;

  static void configure() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'shepherd_watch',
        channelName: 'Watching agents',
        channelDescription:
            'Kept running so Shepherd can tell you when an agent finishes.',
        // Android requires this notification; it should never make a sound.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(_interval),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Returns whether the service is actually running afterwards — the
  /// notification permission is the user's to refuse.
  static Future<bool> start() async {
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      final result = await FlutterForegroundTask.requestNotificationPermission();
      if (result != NotificationPermission.granted) return false;
    }
    // Doze suspends network access for idle apps, so a watcher that only
    // holds a wake lock still goes deaf a few minutes after the screen turns
    // off. The exemption is the user's to grant and this is the moment to ask
    // — they have just said they want to be told when an agent stops.
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    configure();
    if (await FlutterForegroundTask.isRunningService) return true;
    final result = await FlutterForegroundTask.startService(
      // specialUse rather than dataSync alone: Android 15 stops a dataSync
      // service after six hours in a day, which is most of a working night.
      serviceTypes: const [
        ForegroundServiceTypes.specialUse,
        ForegroundServiceTypes.dataSync,
      ],
      serviceId: 4201,
      notificationTitle: 'Shepherd',
      notificationText: 'Watching your agents',
      callback: watcherCallback,
    );
    return result is ServiceRequestSuccess;
  }

  /// What the watcher is actually doing, for Settings to show. Without this
  /// the switch is the only feedback, and a switch that failed silently looks
  /// exactly like one that worked.
  static Future<WatchStatus> status() async => WatchStatus(
        running: await FlutterForegroundTask.isRunningService,
        notificationsAllowed:
            await FlutterForegroundTask.checkNotificationPermission() ==
                NotificationPermission.granted,
        exemptFromBatteryOptimisation:
            await FlutterForegroundTask.isIgnoringBatteryOptimizations,
      );

  /// Hand the running service the quiet window; it is a separate isolate, so
  /// this is how a setting reaches it without a restart.
  static Future<void> setQuietMinutes(int minutes) async {
    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask({'quietMinutes': minutes});
    }
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

class WatchStatus {
  final bool running;
  final bool notificationsAllowed;
  final bool exemptFromBatteryOptimisation;

  const WatchStatus({
    required this.running,
    required this.notificationsAllowed,
    required this.exemptFromBatteryOptimisation,
  });

  /// The one thing wrong, in the order it has to be fixed.
  String? get problem {
    if (!notificationsAllowed) return 'Notifications are blocked in Android.';
    if (!running) return 'The watcher is not running.';
    if (!exemptFromBatteryOptimisation) {
      return 'Battery optimisation is on, so this will go quiet '
          'a few minutes after the screen does.';
    }
    return null;
  }
}
