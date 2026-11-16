# LearnMath: design notes

How the app works inside, for people reading or changing the code. The
[README](../README.md) is the overview for users.

## Pipeline and features

1. **Create** a single lesson ("the spectral theorem, with proof") or a course
   (the model plans an outline; lessons are generated one by one or all at once).
   A single lesson first gets a prerequisite check: the lesson model lists what it
   builds on. Items covered by a lesson in the library link to it; missing ones can
   be ticked to create a lesson for them too. Can be skipped (Settings: "Check
   prerequisites") (`lib/ai/prerequisites.dart`, `lib/ui/create_sheet.dart`).
2. **Generate** (`lib/pipeline/generation_service.dart`), one job at a time,
   each stage saved so failures resume where they stopped:
   - notes: Markdown + LaTeX, with a block of SymPy checks appended
     (`lib/ai/prompts.dart`)
   - checks: run on the device, not by a model: SymPy via Pyodide in a hidden
     WebView (`lib/checks`). If any fail, one repair pass rewrites the notes and
     they are checked again. Can be switched off in Settings.
   - proof review, optional: a second model referees the notes (see below)
   - narration script: a lecture written for the ear, as `SECTION/SAY/SHOW/PAUSE`
     lines. `SAY` is spoken (math in words), `SHOW` is the subtitle (math in
     LaTeX), `PAUSE` is thinking time after a statement.
   - audio: every segment is synthesized separately, engine padding is trimmed
     and the scripted pauses (times the user's "thinking pauses" setting) are
     inserted, giving one WAV with exact subtitle timings
     (`lib/tts/lecture_audio_builder.dart`).
   With a batch model (`GPT-6.1 Sol` or `GPT-6.1 Terra`) the notes and script
   requests go to OpenRouter's Batch API; the job leaves the queue and the lesson
   resumes when the answer arrives (`lib/pipeline/generation_service.dart`).
3. **Study** (`lib/ui/lesson_screen.dart`): Listen / Notes / PDF tabs; on
   screens >= 840 dp the player sits next to the notes.
   - In the Notes tab, definitions, theorems (also lemmas, propositions,
     corollaries), proofs, examples and remarks sit in colour-coded boxes, found
     from the bold label they start with (`groupNoteBlocks`, `NoteBox` in
     `lib/notes/notes_view.dart`). A proof runs to its end mark, an example to the
     next heading or label, the others take the labelled paragraph with the formulas,
     lists and sentences that continue it. Colours: blue theorems, green
     definitions, amber examples, violet remarks, an outline for proofs.
   - A backslash at the end of a line inside a formula (LaTeX's control space)
     is written as `\ ` before rendering; flutter_math would otherwise reject the
     whole formula (`normalizeTex` in `lib/notes/md_blocks.dart`).
   - In a course, the next lesson that has a recording starts about two seconds
     after a lecture ends (Settings: "Play the next lesson automatically")
     (`lib/player/next_lesson.dart`, `lib/player/lecture_player.dart`).
   - A mini-player bar at the bottom of the library, course and lesson screens shows
     the loaded lecture, with back, play/pause, forward (the double-tap skip
     interval) and close; tapping it opens the lesson. On a lesson screen it is
     hidden where that lesson's own player is visible (its Listen tab, or beside
     the notes on a wide screen), and tapping it there switches to Listen
     (`lib/player/mini_player.dart`, `_LessonMiniPlayer` in `lib/ui/lesson_screen.dart`).
   - The lecture is a media session (`audio_service`,
     `lib/player/lecture_audio_handler.dart`): a notification and lock-screen
     controls like a music app's (previous section, back, play/pause, forward, next
     section), Bluetooth and headset buttons. The lesson title, course and current
     section are shown; tapping the notification opens the lesson. The player
     attaches itself to the handler started in `main.dart`.
   - "Explain this again differently" pauses the lecture and asks the lesson model
     for a different explanation of the current point (3 to 5 spoken sentences).
     It is spoken with the current voice, shown as subtitle, and the lecture then
     resumes at the start of the segment. It plays through the lecture's own player,
     so the media session and audio focus stay one
     (`lib/player/reexplain.dart`, `lib/tts/engine_factory.dart`).

4. **Ask** (`lib/chat`): every lesson has a Chat tab with a tutor grounded in
   that lesson's notes. Long-press a paragraph in the notes ("Ask about this")
   or use the ask button in the player to attach an excerpt to the question.

**Check yourself**: lectures end with a "Check yourself" section: three or four
questions, a pause to think, then the answer. Settings: "Questions at the end of a
lecture"; applies to lectures scripted from now on.

**Review lectures** (`GenerationService.makeDueRecaps`, `lib/pipeline/generation_service.dart`):
three days after a lecture has been listened to the end, a three-minute review of it
is created as a standalone lesson "Review: <title>". It is scripted from the original
notes in question-pause-answer style, with the Summary section as its notes. Due
reviews are created when the app starts or returns to the foreground. Settings:
"Review lectures".

**Exercises** (`lib/exercises`): an "Exercises (N)" button on the notes opens a sheet
with each exercise and "Hint" / "Solution" on demand. The lesson model writes the
answers and they are stored with the lesson; a solution's computations are SymPy-checked
like the notes.

**Proof review** (`lib/checks/proof_review.dart`, prompts in `lib/ai/prompts.dart`)
is optional and off by default. Switch "Verify proofs with a second model" on in
Settings, or run it per finished lesson from the lesson menu. A model from another
family (default `anthropic/claude-opus-5.5`, reasoning effort high) referees the
notes for wrong hypotheses, smuggled premises and unsupported steps. The lesson
model then judges each reported issue, since the reviewer raises false alarms. If
real issues remain, the notes are rewritten once, the SymPy checks re-run, and the
rewrite is refereed again; what is still wrong is shown above the notes. On a
finished lesson the review only reports; notes and recording are not changed. It
costs several times what writing the lesson does. Uses the Batch API in batch mode.

**Your own books** (`lib/books`): import a PDF; chapters come from its
bookmarks (split into sections when long), from an AI reading of the table of
contents, or from even page ranges, and can be edited before import. A book is
stored as a course whose lessons are page ranges. Opening a chapter shows the
original pages (Book tab); "Read this chapter in" transcribes them to
Markdown + LaTeX, one request per page with a vision model through OpenRouter
(default `openai/gpt-6-luna`) or optionally with Mathpix. After that the
chapter has notes, chat (with page citations) and, on request, an audio
lecture scripted in consecutive parts so long chapters work.

**Quiz** (`lib/quiz`): every lesson has a Quiz tab. Pick the difficulty (easy: recall,
medium: understanding, hard: transfer), the kind (multiple choice, free answer, or
mixed) and the number of questions (3, 5, 8, 10). The lesson model writes the whole
quiz in one request from the full notes, so the questions cover different parts of
the lesson, and it is told the questions of the last four quizzes so it asks
something else. Options are shuffled on arrival. A free answer is typed and judged
by the lesson model against the notes on its idea, not its wording (correct, partly
right, not quite, with a sentence of feedback); partly right counts half. Without a
key, or when grading fails, the reference answer is shown and the student marks the
answer themselves. "Copy prompt" / "Paste answer" on the same tab have an outside
assistant write the quiz (the prompt contains the notes); pasted quizzes are stored
with the lesson like the others. Quizzes live in their own store (`quiz_store.dart`),
not in the lesson record.

A quiz can also be ordered through the Batch API ("Batch · half price" next to
the model; "Now" stays the recommended default). It is stored at once as waiting
("Waiting for the batch answer · ordered 10:42", with a button to stop waiting),
collected by `GenerationService.pollBatches` like a lesson's answer (`orderQuiz`,
`_collectQuiz`), and announced with "Quiz ready"; the notification opens the lesson
on its Quiz tab (`/lesson/<id>?tab=quiz`). With the app closed, the background check
says "A quiz has arrived". A quiz whose answer cannot be read shows the reason and
"Order again". Grading stays immediate. Lessons and quizzes waiting for batches
share the polling, the background check, the keep-alive count and batch deletion
(`_waiters` in `generation_service.dart`). The pipeline and the Quiz tab both write
the quiz store, so changes go through `QuizStore.update` (one transaction) and the
tab follows `QuizStore.watch`.

**Review of what you studied** (`GenerationService.createReview`, `lib/ui/review_sheet.dart`,
`lib/cards`): the cards icon in the library lists the studied lessons (listened to
the end, or "Mark as studied" in the lesson menu) and makes a review of the ones
ticked. The review is a lesson of its own with a Cards tab in place of the PDF:
flashcards, a short lesson with its lecture, and a quiz and a chat that cover all
the lessons. It is not written from the full notes: each lesson first gets a key
summary (definitions, statements with hypotheses, proof ideas, examples; one
request per lesson, all in one batch, stored as `Lesson.digest` and reused by
later reviews), and the review, its quizzes and its chat work from those.
Flashcards come back at growing intervals (1, 3, 7, 14, 30 days after "Got it";
"Again" asks the card again in the same session and resets it).

**Continuing a course** (`GenerationService.continueCourse`, `lib/ui/continue_sheet.dart`):
"Continue with part N" on a course page plans the next part of its series (any number
of parts; asked from an earlier part it still continues after the last one). The
planner gets every lesson of the earlier parts, numbered E1, E2, ... across parts,
with its key summary (`Lesson.digest`; lessons with notes but no summary get one
first, a few at a time while the student waits, kept for reviews and later parts;
else the notes' Summary section; an unwritten lesson gives its brief), plus an
optional "what should part N cover". Its plan adds `ASSUMES: E3, E7` per lesson,
stored as `Lesson.buildsOn`. A lesson of a later part is written knowing the earlier
parts' lesson titles and the summaries of the lessons it builds on
(`courseContext`, `Prompts._courseBlock`). Parts are separate courses linked by
`Course.continues`, `seriesId` and `part`; the library shows a series as one box
(`seriesGroups`), the course page links the neighbouring parts, and playing on
continues into the next part (`nextPart` in `lib/player/next_lesson.dart`). "Plan it
with your own AI assistant" gives the same planning prompt to copy, without
writing summaries (`continuationPrompt`, `/import-course?continues=<id>`).

**Lessons written elsewhere** (`lib/ui/import_lesson_screen.dart`, `lib/ai/lesson_import.dart`):
for students without an OpenRouter key but with a ChatGPT, Claude or Gemini
subscription. "Or write it with your own AI assistant" in the create sheet gives
out one prompt for the topic (`Prompts.externalLesson`: the same rules as the notes,
checks and script prompts, asking for one code block with `<<<NOTES`, `<<<CHECKS`
and `<<<SCRIPT` regions) to copy or share. The answer comes back from the clipboard
or a `.md`/`.txt` file; the screen shows what it found (title, length, warnings) and
takes a continuation when the answer was cut off. The lesson is then SymPy-checked
and recorded on the device with no model request. Failed checks are shown but the
notes are not rewritten, since the script came with them. Notes without a script
can be imported with a key; the script is then written here.

A course can be brought over the same way. "Or plan it with your own AI assistant"
(create sheet, Course) gives out the outline prompt (`Prompts.externalOutline`); the
pasted `COURSE/DESCRIPTION/LESSON/BRIEF` answer is previewed and stored as a course
with its lessons pending (`GenerationService.importCourse`). Each planned lesson is
then written outside one at a time: "Write lesson N with your own AI" on the course
page (or tapping a planned lesson when there is no key) opens the import screen for
that lesson, whose prompt carries its brief and its place in the course, and the
answer fills that lesson (`importLesson(into:)`), keeping its title and order.

**Backup** (`lib/core/backup.dart`, `lib/ui/backup_section.dart`): Settings, "Your
data". "Export all data" writes one zip (every database record: courses, lessons
with notes and scripts, chats, quizzes, flashcards, listening positions, settings;
plus the PDFs of imported books) and opens the share sheet. The recordings are
optional: without them the file is small and each lecture is recorded again on the
other phone from its stored script ("Record the lecture", no key needed). "Import a
backup" merges by id: records in the backup replace the ones with the same id,
everything else stays. API keys are never in the file. Lessons that were mid-way
are imported as failed-with-retry, except those waiting for a batch.

**Notifications for a course**: lessons of one course that finish in the same run
are announced once ("Course ready: N lessons"), when the last of them is done; a
single lesson is announced as itself. The background check announces an arrived
batch once per batch ("12 lessons can continue ... not finished yet"), not once
per lesson. A lesson in the batch queue says what it is waiting for: the notes, the
lecture script (a second request, after the notes) or the proof review.

Speech is either an on-device sherpa-onnx model, downloaded on first use:
Kokoro (103 MB, 11 voices, the default), Kitten Nano 0.8 (31 MB, 8 voices) or
Piper LJSpeech (67 MB, 1 voice); or an OpenRouter speech model. Lesson text comes
from OpenRouter. The model is picked where it is used (`lib/ui/model_picker.dart`),
not in Settings: in the create sheet for a lesson or a course, in the review
sheet, on a lesson that is not written yet (or failed), in the chat and in the
quiz. The menu always offers `GPT-6.1 Sol (batch)` (`openai/gpt-6.1-sol`, the
default), `GPT-6.1 Terra (batch)`, `GPT-6 Luna (batch)` and a custom model id;
lessons and reviews also get `GPT-6 Luna (immediate)` and a Batch API switch for
the custom model. Chat and quizzes are answered while the student waits, so
there the same models are asked right away and the batch discount does not
apply, except for a quiz ordered for later (see Quiz). The reasoning effort can be set next to the model (model default,
minimal, low, medium, high, extra high, max); high is marked as recommended and
is the default. The choice made for a lesson is stored on it (`Lesson.model`);
the last one is remembered as the starting point for the next. The chat model
also answers exercise hints and solutions and "Explain this again differently".
Each lesson shows which model wrote it ("Written by GPT-6.1 Sol (batch) · high"
above the notes, the model name in the library). The API key is kept in secure storage.

Batch presets cost about half as much and answer within 24 h, usually within
minutes. Course outlines and the tutor chat always run immediately. A course (and each later
part) is planned by its own model, apart from the one that writes its lessons:
"Plans the course" in the create sheet and "Plans part N" in the continue sheet
(`PlannerButton`, `AppSettings.plannerModel`, remembered as `plannerChoice`). It
defaults to GPT-6.1 Sol at high effort whatever writes the lessons, is always asked
right away, and gets the chosen reasoning effort. The summaries written before a
later part is planned use the lesson model, asked right away. While the
app is running it polls a waiting batch (every 15 s, backing off to 3 min) and
again when it returns to the foreground. With the app closed, a WorkManager task
checks about every 15 minutes and posts a notification asking the user to open
the app to finish the lesson (`lib/notify/background_batches.dart`). A waiting
lesson survives app restarts. A submitted batch cannot be cancelled on
OpenRouter; cancelling in the app only stops waiting for it.

In batch mode the requests of all queued lessons are submitted together once the
queue is empty, one batch per model. "Generate all remaining" for a course is one
notes batch and later one script batch, not one per lesson. A collected batch is
deleted on OpenRouter after the last lesson sharing it has collected its answer.

While lessons are being worked on or waited for, the app holds an Android
foreground service (`flutter_foreground_task`, type dataSync, persistent low-priority
notification "Working on N lessons" / "Waiting for N batch answers"), so checks,
script submission and recording continue with the screen off or the app in the
background (`lib/notify/keep_alive_service.dart`). Android 15 limits dataSync
services to 6 hours per 24 hours, and the service does not survive the app being
swiped away; in both cases the WorkManager check and its "open the app" notification
remain as fallback.

Notifications (`lib/notify`, flutter_local_notifications) cover: lesson ready,
lesson failed, batch answer arrived, progress while a voice model downloads or a
lecture is recorded, and voice model installed. None is posted while the app is
in the foreground; tapping a lesson notification opens the lesson.

## Code layout

| Path | Contents |
| --- | --- |
| `lib/core` | models, sembast storage, Riverpod providers |
| `lib/ai` | OpenRouter client, prompts, tolerant parsers, lesson generator, prerequisite check |
| `lib/tts` | TTS engines (on-device sherpa-onnx models in an isolate, OpenRouter), WAV writer, lecture builder |
| `lib/checks` | SymPy check format, parser, Pyodide and process runners, banner, proof review |
| `lib/pipeline` | generation queue, batch waiting |
| `lib/notify` | notifications, background batch check, keep-alive foreground service |
| `lib/player` | player logic, subtitle + double-tap UI, mini-player, auto-advance, re-explain |
| `lib/chat` | tutor chat: prompts, store, controller, pane |
| `lib/quiz` | quiz prompts, parser, store, controller, Quiz tab |
| `lib/exercises` | exercise parser, hint/solution prompts and controller, sheet |
| `lib/books` | PDF access, chapter planning, import screen, transcription (vision / Mathpix) |
| `lib/notes` | notes renderer, Markdown parser, PDF exporter and viewer |
| `lib/ui` | library, course, lesson, create sheet, settings |

## The web version

The app also runs in a desktop browser (Chrome or Edge recommended):

```
flutter build web --release --no-wasm-dry-run
python3 tool/serve_web.py            # http://127.0.0.1:8790/
```

`tool/serve_web.py` is a small static server that adds the cross-origin
isolation headers, so WebAssembly gets several threads. The page must be a
secure context (`https://` or `localhost`): WebGPU, the encrypted key storage
and those threads are not available over plain `http://` to another machine.

What differs in a browser (`filesAreBlobs` in `lib/platform/files.dart`):

- **Storage.** The database is IndexedDB (`sembast_web`). Recorded lectures
  are WAV blobs in a second IndexedDB database, under the same path strings as
  on a device (`web/learnmath_web.js`, `lib/platform/files_web.dart`). A
  lecture is assembled in memory before it is stored.
- **Voice.** "In this browser" is Kokoro v1.0 through kokoro-js 1.2.1, in a
  worker (`web/kokoro_worker.js`, `lib/tts/kokoro_web_engine.dart`): on the
  graphics card with WebGPU (fp32 model, about 330 MB), else on the processor
  (q8 model, about 90 MB). kokoro-js comes from jsDelivr and the model from
  Hugging Face, downloaded once and cached by the browser. The OpenRouter
  voice works as on a device. `AppSettings.browserVoice` picks the speaker.
- **Hosting.** The app is published at https://gabirodz.github.io/learnmath/
  from the `learnmath/` folder of the site's repository
  (`Gabirodz/Gabirodz.github.io`, a Jekyll blog built by GitHub Actions).
  `tool/build_pages.sh <site checkout>` builds it with that base path and
  replaces the folder; committing and pushing there deploys it. GitHub Pages
  cannot send the isolation headers, so without WebGPU the voice runs on one
  thread. The blog's theme has a caching service worker for the whole
  domain: `web/learnmath_sw.js` (no fetch handler, scope `/learnmath/`)
  keeps it from controlling the app, and the blog's `_config.yml` lists
  `/learnmath` under `pwa.cache.deny_paths`. `web/flutter_bootstrap.js`
  leaves out Flutter's own, deprecated service worker, which would take the
  same scope.
- **Loading.** A first visit downloads about 6 MB (the app's code, 3.3 MB
  gzipped; the CanvasKit engine, 1.5 MB; fonts). `web/index.html` shows a
  loading screen until Flutter's `flutter-first-frame` event, and
  `web/flutter_bootstrap.js` tells it when the code has arrived.
- **Not in the browser yet:** SymPy checks (the notes keep their checks,
  unrun), importing a PDF book, the PDF of the notes, backups, notifications
  and generation while the tab is closed.

## Development notes

```
flutter analyze
flutter test            # needs `clang` on PATH (pdfrx native hook); a symlink to gcc works
flutter build apk --debug
```

The TTS host test is skipped unless `KOKORO_MODELS_DIR` is set; it takes
`VOICE_MODEL=kokoro|kitten-nano|piper-ljspeech` (see the header of
`test/tts/kokoro_host_test.dart`). The live batch test,
`test/live/live_batch_test.dart`, runs only when `OPENROUTER_API_KEY` is set.
`lib/checks/process_runner.dart` runs the SymPy checks with a local `python3`
and sympy, for tests and development. The Android build enables core library
desugaring, which flutter_local_notifications requires.

`sherpa_onnx` is pinned to 1.13.8: 2.x removed the espeak-ng phonemizer that
the Kokoro English model needs.

`flutter_inappwebview` is on 6.2.0-beta.3 because 6.1.5 does not build with Android
Gradle Plugin 9.1.1, which the current Flutter requires. The app compiles against
Android SDK 37, which flutter_local_notifications requires. `flutter_foreground_task`
is the keep-alive service's dependency (see Pipeline and features).
