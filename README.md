# LearnMath

Listen to AI-generated graduate math lectures on your phone, with synced
subtitles, LaTeX lecture notes and a PDF. Flutter; Android first, tablet
layout included, web later. Original brief: `description.txt`.

## How it works

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
   - In a course, the next lesson that has a recording starts about two seconds
     after a lecture ends (Settings: "Play the next lesson automatically")
     (`lib/player/next_lesson.dart`, `lib/player/lecture_player.dart`).
   - A mini-player bar at the bottom of the library and course screens shows the
     loaded lecture, with play/pause and close; tapping it opens the lesson
     (`lib/player/mini_player.dart`).
   - "Explain this again differently" pauses the lecture and asks the lesson model
     for a different explanation of the current point (3 to 5 spoken sentences).
     It is spoken with the current voice, shown as subtitle, and the lecture then
     resumes at the start of the segment. It plays through the lecture's own player,
     because just_audio_background allows only one player instance
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
costs several times what writing the lesson does (see
`reports/Cost effective math lesson LLMs.md`). Uses the Batch API in batch mode.

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

Speech is either an on-device sherpa-onnx model, downloaded on first use:
Kokoro (103 MB, 11 voices, the default), Kitten Nano 0.8 (31 MB, 8 voices) or
Piper Lessac (67 MB, 1 voice); or an OpenRouter speech model. Lesson text comes
from OpenRouter. The lesson model is chosen in Settings: `GPT-6.1 Sol (batch)`
(`openai/gpt-6.1-sol`, the default), `GPT-6.1 Terra (batch)`, `GPT-6 Luna`
(immediate, the old default), or a custom model slug with its own Batch API
switch. The reasoning effort can be set for any of them (model default, minimal,
low, medium, high, extra high, max); each preset starts from its own (high for
Sol and Terra), and Settings marks Sol (batch) and high as recommended. The API key is kept in secure storage.

Batch presets cost about half as much and answer within 24 h, usually within
minutes. Course outlines and the tutor chat always run immediately. While the
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

## Layout

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

## Develop

```
flutter analyze
flutter test            # needs `clang` on PATH (pdfrx native hook); a symlink to gcc works
flutter build apk --debug
```

The TTS host test is skipped unless `KOKORO_MODELS_DIR` is set; it takes
`VOICE_MODEL=kokoro|kitten-nano|piper-lessac` (see the header of
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
is the keep-alive service's dependency (see How it works).

## Status

Built and unit-tested; **not yet run on a device**. Verified on the host:
parsers, OpenRouter streaming client (mocked), notes rendering at 320 px, PDF
export, Kokoro synthesis + lecture assembly, chapter planning, PDF outline /
page rendering, chat storage and UI states, Mathpix client against a mock,
batch pipeline and grouped batches against a mock OpenRouter, the proof-review loop
against a mock OpenRouter, SymPy checks with python3, the
Pyodide runner page in headless Chromium, synthesis with all three voice
models, the logic of all six features in unit and widget tests with fakes. Not yet verified: real OpenRouter calls (lessons, chat, page
transcription, proof review), real OpenRouter Batch API calls (written from the documentation
and tested against a mock; `test/live/live_batch_test.dart` exercises the real
thing when `OPENROUTER_API_KEY` is set), the real Mathpix service,
playback/background audio, PDF viewer, file picker and model download on a
phone, the foreground service on a phone, notifications and the background batch
check on a phone, and the Pyodide
WebView on Android (the runner page itself was verified in desktop Chromium).
Also not yet verified: on a phone, auto-advance with the screen locked and the
re-explanation clip sharing the lecture's player; the quality of real model output
for re-explanations, recall questions, reviews, hints, solutions and prerequisite lists.

## Next

- First run on a phone; tune prompts and pacing by ear.
- Check transcription quality on ~10 pages of a real book per backend.
- Tap a page citation in chat to jump to that page; whole-book questions.
- Start listening while the rest of the lecture is still being recorded.
- Compress audio (WAV is ~3 MB/min).
- Web build: storage and TTS use `dart:io` and need web implementations.
