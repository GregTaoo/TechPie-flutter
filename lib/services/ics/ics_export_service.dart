import '../../models/course_table.dart';
import 'ics_file_saver.dart';

class StructuredLocation {
  final String keyword;
  final String title;
  final double latitude;
  final double longitude;

  const StructuredLocation({
    required this.keyword,
    required this.title,
    required this.latitude,
    required this.longitude,
  });
}

class IcsExportService {
  static const List<StructuredLocation> _structuredLocations = [
    StructuredLocation(
      keyword: '信息学院',
      title: '上海科技大学信息科学与技术学院',
      latitude: 31.18043,
      longitude: 121.5907,
    ),
    StructuredLocation(
      keyword: '创管学院',
      title: '上海科技大学创业与管理学院',
      latitude: 31.17872,
      longitude: 121.59061,
    ),
    StructuredLocation(
      keyword: '生命学院',
      title: '上海科技大学生命科学与技术学院',
      latitude: 31.1818,
      longitude: 121.59018,
    ),
    StructuredLocation(
      keyword: '物质学院',
      title: '上海科技大学物质科学与技术学院',
      latitude: 31.17894,
      longitude: 121.58821,
    ),
    StructuredLocation(
      keyword: '教学中心',
      title: '上海科技大学教学中心',
      latitude: 31.17772,
      longitude: 121.59093,
    ),
    StructuredLocation(
      keyword: '创艺学院',
      title: '上海科技大学创意与艺术学院',
      latitude: 31.17887,
      longitude: 121.58887,
    ),
    StructuredLocation(
      keyword: '生医工学院',
      title: '上海科技大学生物医学工程学院',
      latitude: 31.17997,
      longitude: 121.59122,
    ),
  ];

  static const String _structuredLocationAddress = '上海市浦东新区中科路1号';

  String buildCalendar({
    required CourseTable table,
    required DateTime termBegin,
    String calendarName = '课表',
  }) {
    final mondayOfWeekOne = termBegin.subtract(
      Duration(days: termBegin.weekday - 1),
    );
    final periodsByIndex = {
      for (final period in table.periods) period.index: period.toPeriod(),
    };

    final buffer = StringBuffer()
      ..writeln('BEGIN:VCALENDAR')
      ..writeln('VERSION:2.0')
      ..writeln('PRODID:-//TechPie//Schedule Export//CN')
      ..writeln('CALSCALE:GREGORIAN')
      ..writeln('METHOD:PUBLISH')
      ..writeln('X-WR-CALNAME:${_escapeText(calendarName)}')
      ..writeln('X-WR-TIMEZONE:Asia/Shanghai');

    for (final course in table.courses) {
      for (int week = 1; week < course.weeks.length; week++) {
        if (course.weeks[week] != '1') continue;

        final monday = mondayOfWeekOne.add(Duration(days: (week - 1) * 7));
        for (final entry in course.times.entries) {
          final day = entry.key;
          final periods = [...entry.value]..sort();
          if (periods.isEmpty) continue;

          final startPeriod = periodsByIndex[periods.first];
          final endPeriod = periodsByIndex[periods.last];
          if (startPeriod == null || endPeriod == null) continue;

          final classDate = monday.add(Duration(days: day - 1));
          final classroom = course.classroom.trim();
          final location = classroom.isEmpty ? '上海科技大学' : '$classroom 上海科技大学';
          final structuredLocation = _findStructuredLocation(classroom);

          buffer.writeln('BEGIN:VEVENT');
          buffer.writeln(
            'UID:${_buildUid(course, week, day, periods.first, periods.last)}',
          );
          buffer.writeln(
            'DTSTAMP:${_formatUtcTimestamp(DateTime.now().toUtc())}',
          );
          buffer.writeln(
            'DTSTART;TZID=Asia/Shanghai:${_formatLocalDateTime(classDate, startPeriod.startTime)}',
          );
          buffer.writeln(
            'DTEND;TZID=Asia/Shanghai:${_formatLocalDateTime(classDate, endPeriod.endTime)}',
          );
          buffer.writeln('SUMMARY:${_escapeText(course.name)}');
          buffer.writeln('LOCATION-TYPE:SCHOOL');
          buffer.writeln('LOCATION:${_escapeText(location)}');
          if (structuredLocation != null) {
            buffer.writeln(
              'GEO:${structuredLocation.latitude};${structuredLocation.longitude}',
            );
            buffer.writeln(
              'X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-ADDRESS="${_escapeAppleText(_structuredLocationAddress)}";X-APPLE-RADIUS=200;X-TITLE="${_escapeAppleText(structuredLocation.title)}":geo:${structuredLocation.latitude},${structuredLocation.longitude}',
            );
          }
          if (course.teachers.trim().isNotEmpty) {
            buffer.writeln('DESCRIPTION:${_escapeText(course.teachers)}');
          }
          buffer.writeln('SEQUENCE:0');
          buffer.writeln('END:VEVENT');
        }
      }
    }

    buffer.writeln('END:VCALENDAR');
    return buffer.toString();
  }

  Future<SavedIcsFile> saveCalendar({
    required CourseTable table,
    required DateTime termBegin,
    required String fileName,
    required IcsSaveLocation location,
    String calendarName = 'Course Table',
  }) {
    final content = buildCalendar(
      table: table,
      termBegin: termBegin,
      calendarName: calendarName,
    );
    return saveIcsFile(fileName, content, location: location);
  }

  StructuredLocation? _findStructuredLocation(String classroom) {
    for (final candidate in _structuredLocations) {
      if (classroom.contains(candidate.keyword)) {
        return candidate;
      }
    }
    return null;
  }

  String _buildUid(
    EamsCourse course,
    int week,
    int day,
    int startPeriod,
    int endPeriod,
  ) {
    final seed =
        '${course.name}-${course.classroom}-$week-$day-$startPeriod-$endPeriod';
    return '${Uri.encodeComponent(seed)}@techpie';
  }

  String _formatLocalDateTime(DateTime date, String hhmm) {
    final parts = hhmm.split(':');
    final hour = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return '${date.year.toString().padLeft(4, '0')}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}'
        'T'
        '${hour.toString().padLeft(2, '0')}'
        '${minute.toString().padLeft(2, '0')}00';
  }

  String _formatUtcTimestamp(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}'
        '${date.month.toString().padLeft(2, '0')}'
        '${date.day.toString().padLeft(2, '0')}'
        'T'
        '${date.hour.toString().padLeft(2, '0')}'
        '${date.minute.toString().padLeft(2, '0')}'
        '${date.second.toString().padLeft(2, '0')}Z';
  }

  String _escapeText(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll(';', r'\;')
        .replaceAll(',', r'\,')
        .replaceAll('\n', r'\n');
  }

  String _escapeAppleText(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }
}
