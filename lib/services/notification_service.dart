import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../constants/timetable_prompt.dart';
import '../constants/weekday_map.dart';
import '../models/period_model.dart';
import '../theme/primitives.dart';
import 'storage_service.dart';

/// Maps day keys to Dart [DateTime] weekday constants.
/// Derived from the inverse in [kWeekdayMap] (DateTime weekday -> day key).
final Map<String, int> _weekdayMap = {
  for (final entry in kWeekdayMap.entries) entry.value: entry.key,
};

/// Returns the first occurrence of [weekday] at [hour]:[minute] in the
/// app's local timezone that is strictly after [now]. If that exact moment
/// has already passed (or is today but earlier), advances to the following
/// week so the alarm is never scheduled in the past.
///
/// Uses calendar arithmetic (now.day + daysAhead) to remain DST-safe
/// and preserve the exact scheduled hour and minute.
tz.TZDateTime _nextWeeklyOccurrence(
  int weekday,
  int hour,
  int minute,
  tz.TZDateTime now,
) {
  final daysAhead = (weekday - now.weekday) % 7;
  var targetDate = tz.TZDateTime(
    now.location,
    now.year,
    now.month,
    now.day + daysAhead,
    hour,
    minute,
  );
  if (!targetDate.isAfter(now)) {
    targetDate = tz.TZDateTime(
      now.location,
      targetDate.year,
      targetDate.month,
      targetDate.day + 7,
      hour,
      minute,
    );
  }
  return targetDate;
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // ponytail: single shared channel (was 2× const locals).
  static const _channel = MethodChannel('com.jadwal/exact_alarm');

  static bool _initialized = false;
  static bool _timezoneInitialized = false;
  static bool _pendingTimezoneReschedule = false;
  static Future<bool> _scheduleQueue = Future.value(true);
  static int? _lastKnownOffsetMs;
  static String? _lastKnownTzId;

  /// Known legacy aliases mapped to standard IANA timezone database names.
  /// Only contains unambiguous geographic renames, excluding ambiguous abbreviations.
  static const Map<String, String> _timezoneAliases = {
    'Asia/Calcutta': 'Asia/Kolkata',
    'Asia/Saigon': 'Asia/Ho_Chi_Minh',
    'Asia/Katmandu': 'Asia/Kathmandu',
    'Asia/Rangoon': 'Asia/Yangon',
    'Asia/Ulan_Bator': 'Asia/Ulaanbaatar',
    'Asia/Macao': 'Asia/Macau',
    'US/Eastern': 'America/New_York',
    'US/Central': 'America/Chicago',
    'US/Mountain': 'America/Denver',
    'US/Pacific': 'America/Los_Angeles',
    'US/Alaska': 'America/Anchorage',
    'US/Hawaii': 'Pacific/Honolulu',
    'Canada/Eastern': 'America/Toronto',
    'Canada/Central': 'America/Winnipeg',
    'Canada/Mountain': 'America/Edmonton',
    'Canada/Pacific': 'America/Vancouver',
    'Europe/Belfast': 'Europe/London',
    'UTC': 'UTC',
    'GMT': 'UTC',
  };

  /// Resolves the device's timezone into a valid [tz.Location].
  ///
  /// Never defaults blindly to UTC when the device has a non-UTC offset.
  /// If the platform identifier is missing, invalid, or an unmapped OEM string
  /// (e.g. 'Asia/Calcutta'), maps verified aliases or matches a rule-bearing
  /// location in the database preserving Daylight Saving Time behavior.
  static tz.Location _resolveLocation(String? identifier) {
    final expectedOffsetMs = DateTime.now().timeZoneOffset.inMilliseconds;

    if (identifier != null && identifier.trim().isNotEmpty) {
      final trimmed = identifier.trim();
      try {
        final loc = tz.getLocation(trimmed);
        if (loc.currentTimeZone.offset == expectedOffsetMs) {
          return loc;
        }
      } catch (_) {}

      final alias = _timezoneAliases[trimmed];
      if (alias != null) {
        try {
          final loc = tz.getLocation(alias);
          if (loc.currentTimeZone.offset == expectedOffsetMs) {
            return loc;
          }
        } catch (_) {}
      }
    }

    return _fallbackLocationByOffset();
  }

  /// Creates an explicit fixed-offset [tz.Location] matching the device's clock.
  /// Uses a standard GMT±HH:MM identifier compatible with both Dart and
  /// Java's [ZoneId.of] on Android, avoiding incorrect DST rule inheritance.
  static tz.Location _createFixedOffsetLocation(int offsetMilliseconds) {
    const minTime = -8640000000000000;
    final totalMinutes = offsetMilliseconds ~/ 60000;
    final sign = totalMinutes >= 0 ? '+' : '-';
    final absMinutes = totalMinutes.abs();
    final hours = (absMinutes ~/ 60).toString().padLeft(2, '0');
    final minutes = (absMinutes % 60).toString().padLeft(2, '0');
    final name = 'GMT$sign$hours:$minutes';

    return tz.Location(
      name,
      [minTime],
      [0],
      [tz.TimeZone(offsetMilliseconds, isDst: false, abbreviation: name)],
    );
  }

  /// Fallback when native identifier lookup fails or is unmapped.
  /// Samples all 12 months across the year to capture any seasonal transitions (e.g. DST
  /// or Ramadan adjustments). If seasonal shifts exist, searches the timezone database
  /// for a matching rule-bearing location so recurring weekly alarms preserve transition
  /// rules. If the device has no seasonal shifts, constructs a stable fixed-offset location.
  static tz.Location _fallbackLocationByOffset() {
    try {
      final now = DateTime.now();
      final monthlyOffsets = List.generate(
        12,
        (m) => DateTime(now.year, m + 1, 15).timeZoneOffset.inMilliseconds,
      );
      final bool hasTransitions =
          monthlyOffsets.any((o) => o != monthlyOffsets.first);

      if (hasTransitions) {
        for (final loc in tz.timeZoneDatabase.locations.values) {
          try {
            bool matchesAllMonths = true;
            for (var m = 0; m < 12; m++) {
              final sampleDate = DateTime(now.year, m + 1, 15);
              if (tz.TZDateTime.from(sampleDate, loc).timeZoneOffset.inMilliseconds !=
                  monthlyOffsets[m]) {
                matchesAllMonths = false;
                break;
              }
            }
            if (matchesAllMonths) {
              return loc;
            }
          } catch (_) {}
        }
      }

      final offsetMs = now.timeZoneOffset.inMilliseconds;
      return _createFixedOffsetLocation(offsetMs);
    } catch (_) {
      return tz.local;
    }
  }

  /// Fetches and normalizes the native device timezone identifier.
  /// First queries [FlutterTimezone.getLocalTimezone], falling back to the
  /// platform channel method 'getTimeZoneId', returning null if empty or unavailable.
  static Future<String?> _fetchNativeTimezoneId() async {
    String? id;
    try {
      final tzInfo = await FlutterTimezone.getLocalTimezone();
      id = tzInfo.identifier.trim();
    } catch (_) {}
    if (id == null || id.isEmpty) {
      try {
        final platformId = await _channel.invokeMethod<String>('getTimeZoneId');
        id = platformId?.trim();
      } catch (_) {}
    }
    return (id != null && id.isNotEmpty) ? id : null;
  }

  /// Initializes or refreshes the timezone location.
  /// If native timezone lookup fails, falls back to the native platform channel,
  /// or a device-offset location, and updates [_lastKnownOffsetMs] and [_lastKnownTzId].
  static Future<void> _initTimezone() async {
    tz_data.initializeTimeZones();
    final currentId = await _fetchNativeTimezoneId();

    try {
      tz.setLocalLocation(_resolveLocation(currentId));
    } catch (e) {
      debugPrint(
          'NotificationService: timezone lookup failed ($e), falling back to clock offset');
      tz.setLocalLocation(_fallbackLocationByOffset());
    }
    _lastKnownTzId = currentId;
    _lastKnownOffsetMs = DateTime.now().timeZoneOffset.inMilliseconds;
    _timezoneInitialized = true;
  }

  /// Checks whether the device's clock offset or timezone identifier changed since initialization.
  /// If changed, re-resolves the timezone and reschedules reminders so they remain accurate
  /// across daylight-saving transitions and timezone changes.
  ///
  /// Returns true if the timezone is current and scheduling succeeded or was not needed.
  /// Returns false if rescheduling failed, retaining the pending state for retry.
  static Future<bool> ensureTimezoneCurrent({bool rescheduleOnChange = true}) async {
    final currentOffsetMs = DateTime.now().timeZoneOffset.inMilliseconds;
    final currentId = await _fetchNativeTimezoneId();

    if (!_timezoneInitialized) {
      await _initTimezone();
      return true;
    }

    final bool offsetChanged = _lastKnownOffsetMs != currentOffsetMs;
    final bool idChanged = _lastKnownTzId != currentId;

    if (offsetChanged || idChanged) {
      await _initTimezone();
      _pendingTimezoneReschedule = true;
    }

    if (_pendingTimezoneReschedule && rescheduleOnChange) {
      _scheduleQueue = _scheduleQueue.then((_) async {
        if (!_pendingTimezoneReschedule) return true;
        try {
          // Re-fetch current active timetable at execution time so an in-flight
          // import or switch is never overwritten with an older timetable snapshot.
          final timetableData = await StorageService.loadTimetable();
          if (timetableData != null) {
            final rawTimetable = timetableData['timetable'];
            if (rawTimetable is Map) {
              return await _doScheduleAll(rawTimetable.cast<String, dynamic>());
            }
          }
          _pendingTimezoneReschedule = false;
          return true;
        } catch (e) {
          debugPrint(
              'NotificationService.ensureTimezoneCurrent reschedule failed: $e');
          return false;
        }
      }, onError: (_) => false);
      return await _scheduleQueue;
    }

    return !_pendingTimezoneReschedule;
  }

  /// Must be called once before any other method, ideally in main()
  /// before runApp().
  static Future<void> init() async {
    if (_initialized) return;

    await _initTimezone();

    const androidSettings = AndroidInitializationSettings('ic_notification');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint('Notification tapped: payload=${response.payload}');
        },
      );
    } catch (e, stack) {
      debugPrint('NotificationService.init: plugin initialize failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    // Try to get notification permission immediately on startup
    if (Platform.isAndroid) {
      try {
        final androidImplementation = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await androidImplementation?.requestNotificationsPermission();
      } catch (e) {
        debugPrint(
            'NotificationService.init: requestNotificationsPermission failed: $e');
      }
      // Exact-alarm and battery-optimization permissions are intentionally
      // NOT requested here. They prompt only on explicit user action via
      // requestExactAlarmPermission() (called from the screens), so we don't
      // pester the user on every launch.
    }

    _initialized = true;
  }

  /// Requests notification permission on Android 13+ and iOS.
  /// Returns true if granted (or not required on this platform/version).
  static Future<bool> requestPermission() => requestNotificationPermission();

  /// Requests notification permission specifically.
  /// Returns `true` if granted, `false` if denied.
  /// If permanently denied, the runtime dialog won't show —
  /// the caller must direct the user to system settings.
  static Future<bool> requestNotificationPermission() async {
    final status = await Permission.notification.status;
    if (status.isGranted) return true;

    // If permanently denied, the runtime dialog won't show —
    // the caller must direct the user to system settings.
    if (status.isPermanentlyDenied) return false;

    final result = await Permission.notification.request();
    return result.isGranted;
  }

  /// Quick check: are notification permissions granted?
  static Future<bool> arePermissionsGranted() async {
    try {
      final notif = await Permission.notification.status;
      return notif.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Checks if exact alarm permission (SCHEDULE_EXACT_ALARM) is granted.
  /// On Android 14+ (API 34+), this is a special permission that must be
  /// explicitly granted by the user in system settings.
  static Future<bool> hasExactAlarmPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('canScheduleExactAlarms');
      return result ?? false;
    } catch (_) {
      // Fallback: assume not available on older Android versions
      return true;
    }
  }

  /// Opens the system settings page for exact alarm permission.
  /// On Android 14+, users must manually enable "Alarms & reminders".
  /// Returns `true` if permission is now granted, `false` otherwise.
  static Future<bool> requestExactAlarmPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await hasExactAlarmPermission()) return true;

      // Request via platform channel (opens Alarms & reminders settings)
      final launched = await _channel.invokeMethod<bool>('requestExactAlarm');
      if (launched == true) return false;

      // Fallback only if the exact alarm intent couldn't launch
      await openAppSettings();
      return await hasExactAlarmPermission();
    } catch (e, stack) {
      debugPrint('NotificationService.requestExactAlarmPermission failed: $e');
      debugPrintStack(stackTrace: stack);
      try {
        await openAppSettings();
      } catch (_) {}
      return false;
    }
  }

  /// Requests that Android exempt Jadwal from battery optimization.
  ///
  /// On stock Android, exact alarms fire reliably once SCHEDULE_EXACT_ALARM
  /// is granted. On OEM skins (OnePlus/OxygenOS, Xiaomi/MIUI, Huawei/EMUI,
  /// Oppo/ColorOS, Vivo/OriginOS), the system kills background processes
  /// even when that permission is granted, silently dropping scheduled
  /// alarms. The only code-side mitigation is to ask the user to add the
  /// app to the battery-optimization allow-list.
  ///
  /// Returns `true` if battery optimization is disabled for Jadwal.
  /// If denied or restricted, opens the system battery-optimization
  /// settings page so the user can grant it manually.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) {
        debugPrint('NotificationService: battery optimization already disabled');
        return true;
      }

      if (status.isPermanentlyDenied) {
        debugPrint(
            'NotificationService: battery optimization permanently denied — opening settings');
        await _openBatteryOptimizationSettings();
        return false;
      }

      final result = await Permission.ignoreBatteryOptimizations.request();
      if (result.isGranted) {
        debugPrint('NotificationService: battery optimization disabled by user');
        return true;
      }

      debugPrint('NotificationService: battery optimization denied by user');
      await _openBatteryOptimizationSettings();
      return false;
    } catch (e, stack) {
      debugPrint(
          'NotificationService.requestIgnoreBatteryOptimizations failed: $e');
      debugPrintStack(stackTrace: stack);
      try {
        await _openBatteryOptimizationSettings();
      } catch (_) {}
      return false;
    }
  }

  static Future<void> _openBatteryOptimizationSettings() async {
    // Best-effort: try the direct deep-link first. On OnePlus/OxygenOS
    // this is the "Battery > App battery management > Jadwal" page.
    try {
      final ok = await _channel.invokeMethod<bool>('openSystemSettings', {
        'action':
            'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS',
      });
      if (ok == true) return;
    } catch (e) {
      debugPrint(
          'NotificationService: deep-link to battery optimization failed, falling back: $e');
    }
    // Fallback: open app details page.
    await openAppSettings();
  }

  /// Schedules recurring weekly notifications for every period across all
  /// days in the timetable. Each notification fires 5 minutes before the
  /// period starts, on the correct day of the week.
  ///
  /// Uses [DateTimeComponents.dayOfWeekAndTime] so alarms survive reboots
  /// via the [ScheduledNotificationBootReceiver] already declared in the
  /// Android manifest.
  ///
  /// Safe to call repeatedly — schedules are serialized sequentially and cancel
  /// all previous notifications first. Returns true if all alarms registered successfully.
  static Future<bool> scheduleAll(Map<String, dynamic> timetable) {
    _scheduleQueue = _scheduleQueue.then(
      (_) => _doScheduleAll(timetable),
      onError: (_) => _doScheduleAll(timetable),
    );
    return _scheduleQueue;
  }

  static Future<bool> _doScheduleAll(Map<String, dynamic> timetable) async {
    if (!_initialized) {
      await init();
    } else {
      await ensureTimezoneCurrent(rescheduleOnChange: false);
    }

    final startTzId = _lastKnownTzId;
    final startOffset = _lastKnownOffsetMs;

    bool allSucceeded = true;
    try {
      await _plugin.cancelAll();
    } catch (e) {
      allSucceeded = false;
      debugPrint('NotificationService._doScheduleAll: cancelAll failed: $e');
    }

    const androidDetails = AndroidNotificationDetails(
      'period_reminders',
      'Period Reminders',
      channelDescription: 'Reminds you 5 minutes before each class period',
      importance: Importance.high,
      priority: Priority.high,
      groupKey: 'com.jadwal.period_reminders',
      color: Primitives.actionGold,
      category: AndroidNotificationCategory.reminder,
      onlyAlertOnce: true,
      // ponytail: single live reminder — fires 5min early, auto-clears ~5min into period.
      timeoutAfter: 10 * 60 * 1000,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);

    final now = tz.TZDateTime.from(DateTime.now(), tz.local);
    final hasExact = await hasExactAlarmPermission();
    final scheduleMode = hasExact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    final Map<String, dynamic> daysMap =
        timetable.containsKey('timetable') && timetable['timetable'] is Map
            ? (timetable['timetable'] as Map).cast<String, dynamic>()
            : timetable;

    for (var dayIndex = 0; dayIndex < kDayKeys.length; dayIndex++) {
      final dayKey = kDayKeys[dayIndex];
      final dayList = daysMap[dayKey] as List? ?? [];
      if (dayList.isEmpty) continue;

      final weekday = _weekdayMap[dayKey];
      if (weekday == null) continue;

      for (final entry in dayList) {
        if (entry is! Map) {
          allSucceeded = false;
          continue;
        }
        final period = Period.fromJson(Map<String, dynamic>.from(entry));
        final start = period.startTime;
        if (start == null) {
          allSucceeded = false;
          continue;
        }

        // Compute the first upcoming occurrence of this period's 5-min-before
        // time on the *target* weekday (not today's), so each reminder fires
        // on the correct day of the week.
        final reminder = start.subtract(const Duration(minutes: 5));
        final targetWeekday = (start.hour == 0 && start.minute < 5)
            ? (weekday == 1 ? 7 : weekday - 1)
            : weekday;
        final scheduledDate = _nextWeeklyOccurrence(
          targetWeekday,
          reminder.hour,
          reminder.minute,
          now,
        );

        // Unique ID: dayIndex (0-6) * 100 + periodNumber -> supports up to 99 periods without collisions.
        final notifId = dayIndex * 100 + period.periodNumber;

        final title = period.subject.isNotEmpty
            ? 'Period ${period.periodNumber} · ${period.subject}'
            : 'Period ${period.periodNumber}';
        final room = period.classroom.trim();
        final body = room.isNotEmpty
            ? 'Starts at ${period.start} in $room'
            : 'Starts at ${period.start}';

        bool registered = false;
        try {
          await _plugin.zonedSchedule(
            notifId,
            title,
            body,
            scheduledDate,
            details,
            androidScheduleMode: scheduleMode,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          );
          registered = true;
        } catch (e) {
          // If exact alarm mode threw SecurityException (Android 14+), retry once with inexact
          if (scheduleMode != AndroidScheduleMode.inexactAllowWhileIdle) {
            try {
              await _plugin.zonedSchedule(
                notifId,
                title,
                body,
                scheduledDate,
                details,
                androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
                uiLocalNotificationDateInterpretation:
                    UILocalNotificationDateInterpretation.absoluteTime,
                matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
              );
              registered = true;
            } catch (_) {}
          }
          if (!registered) {
            allSucceeded = false;
            debugPrint(
                'NotificationService._doScheduleAll: zonedSchedule for $dayKey period ${period.periodNumber} failed: $e');
          }
        }
      }
    }
    if (allSucceeded &&
        _lastKnownTzId == startTzId &&
        _lastKnownOffsetMs == startOffset) {
      _pendingTimezoneReschedule = false;
    }
    return allSucceeded;
  }

  /// Sends an immediate test notification to verify sound, icon, and delivery.
  static Future<void> showTestNotification() async {
    if (!_initialized) await init();
    const androidDetails = AndroidNotificationDetails(
      'period_reminders',
      'Period Reminders',
      channelDescription: 'Reminds you 5 minutes before each class period',
      importance: Importance.high,
      priority: Priority.high,
      color: Primitives.actionGold,
      category: AndroidNotificationCategory.reminder,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(
      9999,
      'Notification Test',
      'Class reminders are working properly.',
      details,
    );
  }

  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
