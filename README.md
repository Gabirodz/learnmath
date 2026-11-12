# LearnMath

Listen to AI-generated graduate math lectures on your phone, with synced
subtitles, LaTeX lecture notes and a PDF. Flutter; Android first, tablet
layout included, web later. Original brief: `description.txt`.

## How it works

1. **Create** a single lesson ("the spectral theorem, with proof") or a course
   (the model plans an outline; lessons are generated one by one or all at once).
2. **Generate** (`lib/pipeline/generation_service.dart`), one job at a time,
   each stage saved so failures resume where they stopped:
   - notes: Markdown + LaTeX (`lib/ai/prompts.dart`)
   - narration script: a lecture written for the ear, as `SECTION/SAY/SHOW/PAUSE`
     lines. `SAY` is spoken (math in words), `SHOW` is the subtitle (math in
     LaTeX), `PAUSE` is thinking time after a statement.
   - audio: every segment is synthesized separately, engine padding is trimmed
     and the scripted pauses (times the user's "thinking pauses" setting) are
     inserted, giving one WAV with exact subtitle timings
     (`lib/tts/lecture_audio_builder.dart`).
3. **Study** (`lib/ui/lesson_screen.dart`): Listen / Notes / PDF tabs; on
   screens >= 840 dp the player sits next to the notes.

4. **Ask** (`lib/chat`): every lesson has a Chat tab with a tutor grounded in
   that lesson's notes. Long-press a paragraph in the notes ("Ask about this")
   or use the ask button in the player to attach an excerpt to the question.

**Your own books** (`lib/books`): import a PDF; chapters come from its
bookmarks (split into sections when long), from an AI reading of the table of
contents, or from even page ranges, and can be edited before import. A book is
stored as a course whose lessons are page ranges. Opening a chapter shows the
original pages (Book tab); "Read this chapter in" transcribes them to
Markdown + LaTeX, one request per page with a vision model through OpenRouter
(default `openai/gpt-6-luna`) or optionally with Mathpix. After that the
chapter has notes, chat (with page citations) and, on request, an audio
lecture scripted in consecutive parts so long chapters work.

Speech is either on-device Kokoro (sherpa-onnx, ~100 MB model downloaded on
first use) or an OpenRouter speech model. Lesson text comes from OpenRouter
(default model `openai/gpt-6-luna`); the API key is kept in secure storage.

## Layout

| Path | Contents |
| --- | --- |
| `lib/core` | models, sembast storage, Riverpod providers |
| `lib/ai` | OpenRouter client, prompts, tolerant parsers, lesson generator |
| `lib/tts` | TTS engines (Kokoro isolate, OpenRouter), WAV writer, lecture builder |
| `lib/pipeline` | generation queue |
| `lib/player` | player logic, subtitle + double-tap UI |
| `lib/chat` | tutor chat: prompts, store, controller, pane |
| `lib/books` | PDF access, chapter planning, import screen, transcription (vision / Mathpix) |
| `lib/notes` | notes renderer, Markdown parser, PDF exporter and viewer |
| `lib/ui` | library, course, lesson, create sheet, settings |

## Develop

```
flutter analyze
flutter test            # needs `clang` on PATH (pdfrx native hook); a symlink to gcc works
flutter build apk --debug
```

The Kokoro integration test is skipped unless `KOKORO_MODELS_DIR` is set (see
the header of `test/tts/kokoro_host_test.dart`).

`sherpa_onnx` is pinned to 1.13.8: 2.x removed the espeak-ng phonemizer that
the Kokoro English model needs.

## Status

Built and unit-tested; **not yet run on a device**. Verified on the host:
parsers, OpenRouter streaming client (mocked), notes rendering at 320 px, PDF
export, Kokoro synthesis + lecture assembly, chapter planning, PDF outline /
page rendering, chat storage and UI states, Mathpix client against a mock.
Not yet verified: real OpenRouter calls (lessons, chat, page transcription),
the real Mathpix service, playback/background audio, PDF viewer, file picker
and model download on a phone.

## Next

- First run on a phone; tune prompts and pacing by ear.
- Check transcription quality on ~10 pages of a real book per backend.
- Tap a page citation in chat to jump to that page; whole-book questions.
- Keep generation alive with the screen off (Android foreground service).
- Mini-player on the library screen; play next lesson in a course automatically.
- Start listening while the rest of the lecture is still being recorded.
- Compress audio (WAV is ~3 MB/min).
- Web build: storage and TTS use `dart:io` and need web implementations.
