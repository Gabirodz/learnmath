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
