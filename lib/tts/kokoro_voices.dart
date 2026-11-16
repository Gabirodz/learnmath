/// A voice of the Kokoro model that runs in the browser (kokoro-js).
class KokoroVoice {
  const KokoroVoice(this.id, this.name, this.accent, this.gender);

  /// What kokoro-js calls it ("af_heart").
  final String id;
  final String name;
  final String accent;
  final String gender;

  String get label => '$name ($accent, $gender)';

  static KokoroVoice byId(String id) {
    for (final v in kokoroVoices) {
      if (v.id == id) return v;
    }
    return kokoroVoices.first;
  }
}

const defaultKokoroVoice = 'af_heart';

/// The English voices of Kokoro v1.0, the better-rated ones first within
/// each accent (grades from the model's own voice table).
const kokoroVoices = <KokoroVoice>[
  KokoroVoice('af_heart', 'Heart', 'US', 'female'),
  KokoroVoice('af_bella', 'Bella', 'US', 'female'),
  KokoroVoice('af_nicole', 'Nicole', 'US', 'female'),
  KokoroVoice('af_aoede', 'Aoede', 'US', 'female'),
  KokoroVoice('af_kore', 'Kore', 'US', 'female'),
  KokoroVoice('af_sarah', 'Sarah', 'US', 'female'),
  KokoroVoice('af_alloy', 'Alloy', 'US', 'female'),
  KokoroVoice('af_nova', 'Nova', 'US', 'female'),
  KokoroVoice('af_sky', 'Sky', 'US', 'female'),
  KokoroVoice('af_jessica', 'Jessica', 'US', 'female'),
  KokoroVoice('af_river', 'River', 'US', 'female'),
  KokoroVoice('am_fenrir', 'Fenrir', 'US', 'male'),
  KokoroVoice('am_michael', 'Michael', 'US', 'male'),
  KokoroVoice('am_puck', 'Puck', 'US', 'male'),
  KokoroVoice('am_echo', 'Echo', 'US', 'male'),
  KokoroVoice('am_eric', 'Eric', 'US', 'male'),
  KokoroVoice('am_liam', 'Liam', 'US', 'male'),
  KokoroVoice('am_onyx', 'Onyx', 'US', 'male'),
  KokoroVoice('am_adam', 'Adam', 'US', 'male'),
  KokoroVoice('bf_emma', 'Emma', 'UK', 'female'),
  KokoroVoice('bf_isabella', 'Isabella', 'UK', 'female'),
  KokoroVoice('bf_alice', 'Alice', 'UK', 'female'),
  KokoroVoice('bf_lily', 'Lily', 'UK', 'female'),
  KokoroVoice('bm_fable', 'Fable', 'UK', 'male'),
  KokoroVoice('bm_george', 'George', 'UK', 'male'),
  KokoroVoice('bm_lewis', 'Lewis', 'UK', 'male'),
  KokoroVoice('bm_daniel', 'Daniel', 'UK', 'male'),
];

/// Splits [text] into pieces of at most [maxChars] characters, at the end of
/// a sentence where there is one, else at a comma, else at a space.
///
/// Kokoro reads at most 510 phonemes at a time and silently drops the rest,
/// so a long sentence is spoken in pieces.
List<String> splitForKokoro(String text, {int maxChars = 240}) {
  final out = <String>[];
  var rest = text.trim();
  while (rest.length > maxChars) {
    final window = rest.substring(0, maxChars);
    var cut = -1;
    for (final marks in const ['.!?', ';:', ',', ' ']) {
      for (var i = window.length - 1; i > maxChars ~/ 3; i--) {
        // A mark only ends a piece when a space follows it ("3.14" does not).
        final atEnd = marks == ' '
            ? window[i] == ' '
            : marks.contains(window[i]) &&
                (i + 1 == window.length || window[i + 1] == ' ');
        if (atEnd) {
          cut = i + 1;
          break;
        }
      }
      if (cut != -1) break;
    }
    if (cut == -1) cut = maxChars; // one very long word
    out.add(rest.substring(0, cut).trim());
    rest = rest.substring(cut).trim();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}
