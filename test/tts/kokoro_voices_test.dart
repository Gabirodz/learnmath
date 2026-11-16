import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/tts/kokoro_voices.dart';

void main() {
  group('splitForKokoro', () {
    test('short text comes back as one trimmed piece', () {
      expect(splitForKokoro('  Hello there.  '), ['Hello there.']);
    });

    test('empty or whitespace-only text gives an empty list', () {
      expect(splitForKokoro(''), isEmpty);
      expect(splitForKokoro(' \n\t '), isEmpty);
    });

    test('long text is cut at sentence ends', () {
      const sentences = [
        'The first sentence of this lesson is quite short.',
        'The second one talks about compact sets in a metric space!',
        'Does every closed subset of a compact set stay compact?',
        'Yes, it does, and the proof is a short exercise for you.',
        'The third sentence is here to make the text long enough.',
        'Finally we stop.',
      ];
      final text = sentences.join(' ');
      const max = 60;
      final pieces = splitForKokoro(text, maxChars: max);

      expect(pieces.length, greaterThan(1));
      for (final p in pieces) {
        expect(p.length, lessThanOrEqualTo(max), reason: 'piece: "$p"');
      }
      for (final p in pieces.take(pieces.length - 1)) {
        expect(p.endsWith('.') || p.endsWith('!') || p.endsWith('?'), isTrue,
            reason: 'piece: "$p"');
      }
      expect(pieces.join(' '), text);
    });

    test('long sentence without a full stop is cut after a comma', () {
      final text = List.generate(20, (i) => 'item$i').join(', ');
      const max = 60;
      final pieces = splitForKokoro(text, maxChars: max);

      expect(pieces.length, greaterThan(1));
      for (final p in pieces) {
        expect(p.length, lessThanOrEqualTo(max), reason: 'piece: "$p"');
      }
      for (final p in pieces.take(pieces.length - 1)) {
        expect(p.endsWith(','), isTrue, reason: 'piece: "$p"');
      }
      expect(pieces.join(' '), text);
    });

    test('long run of words without punctuation is cut at spaces', () {
      final words = List.generate(40, (i) => 'word$i');
      final text = words.join(' ');
      const max = 50;
      final pieces = splitForKokoro(text, maxChars: max);

      expect(pieces.length, greaterThan(1));
      for (final p in pieces) {
        expect(p.length, lessThanOrEqualTo(max), reason: 'piece: "$p"');
        for (final w in p.split(' ')) {
          expect(words.contains(w), isTrue, reason: 'split inside a word: "$w"');
        }
      }
      expect(pieces.join(' ').split(' '), words);
    });

    test('a decimal point is not a sentence end', () {
      const text =
          'Pi is 3.14159 here. Then more words follow after that point, '
          'and they keep going on.';
      final pieces = splitForKokoro(text, maxChars: 40);

      expect(pieces.first, 'Pi is 3.14159 here.');
      for (final p in pieces) {
        expect(p.endsWith('3.'), isFalse, reason: 'piece: "$p"');
        expect(p.startsWith('14'), isFalse, reason: 'piece: "$p"');
      }
    });

    test('a single word longer than maxChars is split into pieces', () {
      final word = 'x' * 100;
      const max = 30;
      final pieces = splitForKokoro(word, maxChars: max);

      expect(pieces.length, greaterThan(1));
      for (final p in pieces) {
        expect(p.length, lessThanOrEqualTo(max), reason: 'piece: "$p"');
      }
      expect(pieces.join(), word);
    });

    test('a custom small maxChars is respected', () {
      const text =
          'The first sentence of this lesson is quite short. '
          'The second one talks about compact sets in a metric space! '
          'Does every closed subset of a compact set stay compact?';
      const max = 40;
      final pieces = splitForKokoro(text, maxChars: max);

      expect(pieces.length, greaterThan(1));
      for (final p in pieces) {
        expect(p.length, lessThanOrEqualTo(max), reason: 'piece: "$p"');
      }
      expect(pieces.join(' '), text);
    });
  });

  group('KokoroVoice', () {
    test('byId finds a voice and falls back to the first one', () {
      expect(KokoroVoice.byId('af_bella').name, 'Bella');
      expect(KokoroVoice.byId('zz_unknown').id, kokoroVoices.first.id);
    });

    test('defaultKokoroVoice is an id in kokoroVoices', () {
      expect(kokoroVoices.map((v) => v.id), contains(defaultKokoroVoice));
    });

    test('voice ids are unique and well formed', () {
      final ids = kokoroVoices.map((v) => v.id).toList();
      expect(ids.toSet().length, ids.length);
      final pattern = RegExp(r'^(a|b)(f|m)_[a-z]+$');
      for (final id in ids) {
        expect(pattern.hasMatch(id), isTrue, reason: 'id: "$id"');
      }
    });

    test('label combines name, accent and gender', () {
      expect(KokoroVoice.byId('af_heart').label, 'Heart (US, female)');
    });
  });
}
