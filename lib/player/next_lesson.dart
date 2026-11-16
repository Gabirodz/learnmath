import '../core/models.dart';

/// The lesson that should play after [finished] ends: the next one of the same
/// course, in course order, that has a recording. Lessons that are still being
/// generated, failed, or have no audio are skipped. Null for standalone
/// lessons and for the last playable lesson of a course.
Lesson? nextToPlay(Lesson finished, List<Lesson> courseLessons) {
  final courseId = finished.courseId;
  if (courseId == null) return null;
  Lesson? best;
  for (final l in courseLessons) {
    if (l.courseId != courseId || l.id == finished.id) continue;
    if (l.order <= finished.order) continue;
    if (l.stage != LessonStage.ready || !l.hasAudio) continue;
    if (best == null || l.order < best.order) best = l;
  }
  return best;
}

/// The part that follows [course] in its series (the lowest later part
/// number, so a deleted part is skipped), or null.
Course? nextPart(Course course, List<Course> all) {
  Course? best;
  for (final c in all) {
    if (c.series != course.series || c.part <= course.part) continue;
    if (best == null || c.part < best.part) best = c;
  }
  return best;
}

/// The first lesson of a course, in course order, that has a recording.
Lesson? firstToPlay(List<Lesson> courseLessons) {
  Lesson? best;
  for (final l in courseLessons) {
    if (l.stage != LessonStage.ready || !l.hasAudio) continue;
    if (best == null || l.order < best.order) best = l;
  }
  return best;
}
