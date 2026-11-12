import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../core/storage.dart';
import 'chapter_plan.dart';

class BookImporter {
  BookImporter({required this.repo, required this.paths});

  final LibraryRepository repo;
  final AppPaths paths;

  /// Copies the PDF into app storage and saves the course and its lessons.
  /// Returns the new course id.
  Future<String> import({
    required String sourcePath,
    required String title,
    required int pageCount,
    required List<ChapterPlan> chapters,
  }) async {
    const uuid = Uuid();
    final courseId = uuid.v4();
    final dest = paths.bookPdf(courseId);
    final now = DateTime.now();
    try {
      await Directory(p.dirname(dest)).create(recursive: true);
      await File(sourcePath).copy(dest);
      await repo.saveCourse(Course(
        id: courseId,
        title: title.trim().isEmpty ? 'Untitled book' : title.trim(),
        description: '${chapters.length} chapters · $pageCount pages',
        createdAt: now,
        bookPath: dest,
        bookPageCount: pageCount,
      ));
      for (var i = 0; i < chapters.length; i++) {
        final c = chapters[i];
        await repo.saveLesson(Lesson(
          id: uuid.v4(),
          courseId: courseId,
          order: i,
          title: c.title,
          brief: c.startPage == c.endPage
              ? 'Page ${c.startPage}'
              : 'Pages ${c.startPage}–${c.endPage}',
          createdAt: now,
          sourceStartPage: c.startPage,
          sourceEndPage: c.endPage,
          sourceStopBefore: c.stopBefore,
        ));
      }
    } catch (_) {
      try {
        await repo.deleteCourse(courseId);
      } catch (_) {}
      try {
        final dir = Directory(p.dirname(dest));
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    return courseId;
  }
}
