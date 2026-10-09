import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/models/assignment.dart';
import 'package:techpie/models/course.dart';
import 'package:techpie/models/course_table.dart';
import 'package:techpie/models/custom_course.dart';
import 'package:techpie/services/ics/ics_export_service.dart';

void main() {
  test('custom event UIDs use their stable id and occurrence date', () {
    const table = CourseTable(periods: [], courses: []);
    const first = CustomCourse(
      id: 'a',
      name: '习题课',
      location: '教室',
      weekdays: [3],
      time: ClockCourseTime(startTime: '19:00', endTime: '20:30'),
      weeks: [1],
    );
    const second = CustomCourse(
      id: 'b',
      name: '习题课',
      location: '教室',
      weekdays: [3],
      time: ClockCourseTime(startTime: '19:00', endTime: '20:30'),
      weeks: [1],
    );

    final calendar = IcsExportService().buildCalendar(
      table: table,
      termBegin: DateTime(2026, 9, 7),
      customCourses: const [first, second],
    );

    expect(calendar, contains('UID:custom-a-20260909@techpie'));
    expect(calendar, contains('UID:custom-b-20260909@techpie'));
    expect(calendar, isNot(contains('custom-a-20260909-1-1')));
  });

  test('loaded exams are exported with their stable exam id', () {
    const table = CourseTable(periods: [], courses: []);
    final exam = ExamAssignment(
      id: '263:1222:CS130.01:7987',
      title: '操作系统I 期中考试',
      course: '操作系统I · 教学中心204',
      due: DateTime(2026, 4, 23, 15),
      lateDue: DateTime(2026, 4, 23, 16, 40),
      semesterId: '263',
      location: '教学中心204',
      batchName: '期中考试',
    );

    final calendar = IcsExportService().buildCalendar(
      table: table,
      termBegin: DateTime(2026, 3, 2),
      exams: [exam],
    );

    expect(calendar, contains('UID:exam-263%3A1222%3ACS130.01%3A7987@techpie'));
    expect(calendar, contains('DTSTART;TZID=Asia/Shanghai:20260423T150000'));
  });
}
