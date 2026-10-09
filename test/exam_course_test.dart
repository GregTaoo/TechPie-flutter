import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/models/assignment.dart';
import 'package:techpie/models/course.dart';
import 'package:techpie/models/exam_course.dart';

void main() {
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
  final termBegin = DateTime(2026, 3, 2);
  test('selects current-semester exams once by stable id', () {
    final otherSemester = ExamAssignment(
      id: '262:1222:CS130.01:7987',
      title: exam.title,
      course: exam.course,
      due: exam.due,
      lateDue: exam.lateDue,
      semesterId: '262',
      location: exam.location,
      batchName: exam.batchName,
    );

    final selected = examsForSemester([exam, exam, otherSemester], '263');

    expect(selected, [same(exam)]);
  });

  test('creates a one-off clock-time course in the matching teaching week', () {
    final courses = withExamCourses(
      const [],
      [exam],
      8,
      termBegin,
    );

    expect(courses, hasLength(1));
    final course = courses.single;
    expect(course.source, isA<ExamCourseSource>());
    expect((course.source as ExamCourseSource).id, exam.id);
    expect(course.dayOfWeek, DateTime.thursday);
    expect(course.startTime, '15:00');
    expect(course.endTime, '16:40');
    expect(
      withExamCourses(const [], [exam], 7, termBegin),
      isEmpty,
    );
  });
}
