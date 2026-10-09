import 'assignment.dart';
import 'course.dart';
import 'custom_course.dart';

List<ExamAssignment> examsForSemester(
  Iterable<Assignment> assignments,
  String? semesterId,
) {
  if (semesterId == null) return const [];
  final byId = <String, ExamAssignment>{};
  for (final assignment in assignments.whereType<ExamAssignment>()) {
    if (assignment.semesterId == semesterId) {
      byId[assignment.id] = assignment;
    }
  }
  return byId.values.toList()..sort((a, b) => a.due.compareTo(b.due));
}

List<Course> withExamCourses(
  List<Course> courses,
  Iterable<ExamAssignment> exams,
  int? week,
  DateTime? termBegin, {
  bool includeGhosts = false,
  List<Period> periods = defaultPeriods,
}) {
  final result = [...courses];
  for (final exam in exams) {
    final examWeek = teachingWeekOf(exam.due, termBegin);
    if (examWeek == null) continue;
    final active = week == null || examWeek == week;
    if (!active && !includeGhosts) continue;
    final end = exam.lateDue;
    if (end == null || !end.isAfter(exam.due)) continue;
    final placement = ClockCourseTime(
      startTime: _clock(exam.due),
      endTime: _clock(end),
    ).resolve(periods);
    if (placement == null) continue;

    result.add(
      Course(
        name: exam.title,
        location: exam.location,
        dayOfWeek: exam.due.weekday,
        placement: placement,
        color: CourseColor.error,
        weeksText: _date(exam.due),
        date: exam.due,
        isGhost: !active,
        source: ExamCourseSource(exam.id),
      ),
    );
  }
  return result;
}

String _clock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _date(DateTime value) => '${value.year}-${value.month.toString().padLeft(2, '0')}'
    '-${value.day.toString().padLeft(2, '0')}';
