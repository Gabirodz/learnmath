# Third-party software and data

LearnMath itself is free software under the GNU General Public License,
version 3 or later (see `LICENSE`). It is built from, or fetches when it runs,
the components below. The licences of the Dart and Flutter packages it is
compiled with are listed inside the app: Settings, About, "Open-source
licences".

## Compiled into the app

| Component | Licence | Notes |
| --- | --- | --- |
| eSpeak NG | GPL-3.0-or-later | Turns text into phonemes. Statically linked into the sherpa-onnx library of the Android build. Source: https://github.com/espeak-ng/espeak-ng |
| sherpa-onnx 1.13.8 | Apache-2.0 | The on-device voice engine (Android). https://github.com/k2-fsa/sherpa-onnx |
| Flutter and the Dart packages in `pubspec.yaml` | BSD, MIT, Apache-2.0 | Shown in the app's licences page. |
| Noto Serif, Noto Sans Mono | SIL Open Font License 1.1 | `assets/fonts/OFL-NOTO.txt` |

Because eSpeak NG is part of the Android build, the app as a whole is
distributed under the GPL, version 3 or later.

## Fetched when the app runs

These are not in the repository or in the app package; the app downloads them
on the user's device.

| Component | Licence | Used for |
| --- | --- | --- |
| kokoro-js 1.2.1 | Apache-2.0 | The voice in the browser version, from the jsDelivr CDN. Its bundle includes the `phonemizer` package (Apache-2.0), which embeds eSpeak NG (GPL-3.0-or-later). https://github.com/hexgrad/kokoro |
| Kokoro-82M voice model | Apache-2.0 | Voice model, from Hugging Face (browser) or the sherpa-onnx model releases (Android). https://huggingface.co/hexgrad/Kokoro-82M |
| Kitten TTS Nano 0.8 voice model | See its model page | Optional voice model (Android). https://huggingface.co/KittenML/kitten-tts-nano-0.8 |
| Piper voice `en_US-lessac-medium` | See note below | Optional voice model (Android). |
| Pyodide and SymPy | MPL-2.0 (Pyodide), BSD (SymPy) | Re-running the computations of a lesson (Android), from the jsDelivr CDN. https://github.com/pyodide/pyodide |
| CanvasKit | BSD | Flutter's drawing engine in the browser version, from Google's CDN. |

**Piper `en_US-lessac-medium`.** This voice was trained on the Lessac
Blizzard 2013 corpus, whose licence limits use to research on speech
technology. It is to be replaced by a voice trained on public-domain
recordings (for example `en_US-ljspeech` or `en_US-kristin`).

## Services

The app sends the user's requests to OpenRouter (and, for book import, to
Mathpix when the user chooses it) with the user's own API key. Their terms,
and the terms of the model the user picks, apply to that use.
