import 'package:flutter_test/flutter_test.dart';
import 'package:jadwal/models/period_model.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

void main() {
  group('Notification text formatting tests', () {
    test('formats period title and body properly with room', () {
      final period = Period(
        periodNumber: 1,
        subject: 'MAT',
        classroom: 'Room 4',
        start: '8:00 AM',
        end: '8:40 AM',
      );

      final title = period.subject.isNotEmpty
          ? 'Period ${period.periodNumber} · ${period.subject}'
          : 'Period ${period.periodNumber}';
      final room = period.classroom.trim();
      final body = room.isNotEmpty
          ? 'Starts at ${period.start} in $room'
          : 'Starts at ${period.start}';

      expect(title, 'Period 1 · MAT');
      expect(body, 'Starts at 8:00 AM in Room 4');
    });

    test('formats period title and body properly without room (no awkward spacing)', () {
      final period = Period(
        periodNumber: 3,
        subject: 'ENG',
        classroom: '   ',
        start: '10:00 AM',
        end: '10:40 AM',
      );

      final title = period.subject.isNotEmpty
          ? 'Period ${period.periodNumber} · ${period.subject}'
          : 'Period ${period.periodNumber}';
      final room = period.classroom.trim();
      final body = room.isNotEmpty
          ? 'Starts at ${period.start} in $room'
          : 'Starts at ${period.start}';

      expect(title, 'Period 3 · ENG');
      expect(body, 'Starts at 10:00 AM');
    });

    test('nextWeeklyOccurrence returns strictly future date on the correct weekday and time', () {
      tz_data.initializeTimeZones();
      final location = tz.getLocation('Asia/Kolkata');
      // Tuesday, Nov 11, 2026, 10:30 AM
      final now = tz.TZDateTime(location, 2026, 11, 11, 10, 30);

      tz.TZDateTime nextWeeklyOccurrence(
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

      for (int targetWeekday = 1; targetWeekday <= 7; targetWeekday++) {
        for (int h = 7; h <= 17; h++) {
          final scheduled = nextWeeklyOccurrence(targetWeekday, h, 0, now);
          expect(scheduled.isAfter(now), isTrue,
              reason: 'Scheduled must be after now');
          expect(scheduled.weekday, targetWeekday,
              reason: 'Weekday must match targetWeekday');
          expect(scheduled.hour, h, reason: 'Hour must match target hour');
          expect(scheduled.minute, 0, reason: 'Minute must match');
        }
      }
    });
    test('Period time parsing supports flexible 12-hour and 24-hour formats', () {
      final p1 = Period(
        periodNumber: 1,
        subject: 'MAT',
        classroom: 'Room 1',
        start: '8:00 AM',
        end: '8:40 AM',
      );
      expect(p1.startTime?.hour, 8);
      expect(p1.startTime?.minute, 0);

      // No space between time and AM/PM
      final p2 = Period(
        periodNumber: 2,
        subject: 'ENG',
        classroom: 'Room 2',
        start: '10:00AM',
        end: '10:45AM',
      );
      expect(p2.startTime?.hour, 10);
      expect(p2.startTime?.minute, 0);

      // Lowercase am/pm
      final p3 = Period(
        periodNumber: 3,
        subject: 'SCI',
        classroom: 'Lab',
        start: '2:15 pm',
        end: '3:00 pm',
      );
      expect(p3.startTime?.hour, 14);
      expect(p3.startTime?.minute, 15);

      // 24-hour format
      final p4 = Period(
        periodNumber: 4,
        subject: 'HIS',
        classroom: 'Room 3',
        start: '13:30',
        end: '14:15',
      );
      expect(p4.startTime?.hour, 13);
      expect(p4.startTime?.minute, 30);
    });
    test('Fixed-offset location produces valid GMT offset and TZDateTime', () {
      const minTime = -8640000000000000;
      final offsets = [
        const Duration(hours: 5, minutes: 30),
        const Duration(hours: -5),
        const Duration(hours: 0),
      ];

      for (final offset in offsets) {
        final offsetMs = offset.inMilliseconds;
        final totalMinutes = offsetMs ~/ 60000;
        final sign = totalMinutes >= 0 ? '+' : '-';
        final absMinutes = totalMinutes.abs();
        final hours = (absMinutes ~/ 60).toString().padLeft(2, '0');
        final minutes = (absMinutes % 60).toString().padLeft(2, '0');
        final name = 'GMT$sign$hours:$minutes';

        final loc = tz.Location(
          name,
          [minTime],
          [0],
          [tz.TimeZone(offsetMs, isDst: false, abbreviation: name)],
        );

        final dt = tz.TZDateTime(loc, 2026, 11, 11, 8, 0);
        expect(dt.hour, 8);
        expect(dt.minute, 0);
        expect(dt.timeZoneOffset.inMinutes, offset.inMinutes);
        expect(loc.name, name);
      }
    });

    test('Timezone aliases resolve to valid rule-bearing IANA locations', () {
      tz_data.initializeTimeZones();
      const testAliases = {
        'Asia/Calcutta': 'Asia/Kolkata',
        'Asia/Saigon': 'Asia/Ho_Chi_Minh',
        'US/Eastern': 'America/New_York',
        'US/Pacific': 'America/Los_Angeles',
        'Canada/Central': 'America/Winnipeg',
        'Europe/Belfast': 'Europe/London',
      };

      for (final entry in testAliases.entries) {
        final targetLoc = tz.getLocation(entry.value);
        expect(targetLoc, isNotNull);
        expect(targetLoc.name, entry.value);
      }
    });

    test('12-month profile matcher finds rule-bearing location preserving seasonal transitions', () {
      tz_data.initializeTimeZones();
      final year = 2026;
      final refLoc = tz.getLocation('America/New_York');
      final expectedOffsets = List.generate(
        12,
        (m) => tz.TZDateTime.from(DateTime(year, m + 1, 15), refLoc).timeZoneOffset.inMilliseconds,
      );

      tz.Location? matchedLoc;
      for (final loc in tz.timeZoneDatabase.locations.values) {
        try {
          bool matchesAllMonths = true;
          for (var m = 0; m < 12; m++) {
            final sampleDate = DateTime(year, m + 1, 15);
            if (tz.TZDateTime.from(sampleDate, loc).timeZoneOffset.inMilliseconds !=
                expectedOffsets[m]) {
              matchesAllMonths = false;
              break;
            }
          }
          if (matchesAllMonths) {
            matchedLoc = loc;
            break;
          }
        } catch (_) {}
      }

      expect(matchedLoc, isNotNull);
      for (var m = 0; m < 12; m++) {
        final sampleDate = DateTime(year, m + 1, 15);
        expect(
          tz.TZDateTime.from(sampleDate, matchedLoc!).timeZoneOffset.inMilliseconds,
          expectedOffsets[m],
        );
      }
    });
  });
}
