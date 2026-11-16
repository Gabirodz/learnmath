import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/cards/card_parser.dart';

void main() {
  group('parseCards', () {
    test('reads two plain cards, with and without TOPIC', () {
      final cards = parseCards(r'''FRONT: What is $p$?
BACK: A prime number.
TOPIC: Primes

FRONT: What is a group?
BACK: A set with an associative operation, identity and inverses.
''');
      expect(cards, hasLength(2));
      expect(cards[0].front, r'What is $p$?');
      expect(cards[0].back, 'A prime number.');
      expect(cards[0].topic, 'Primes');
      expect(cards[1].topic, isNull);
      expect(cards[1].box, 0);
      expect(cards[1].dueAt, isNull);
    });

    test('accepts decorated keys', () {
      final cards = parseCards('**Front:** What is \$p\$?\n'
          '### Back: Prime.\n'
          '- TOPIC: Primes\n'
          '- FRONT: second\n'
          '- back: other\n');
      expect(cards, hasLength(2));
      expect(cards[0].front, r'What is $p$?');
      expect(cards[0].back, 'Prime.');
      expect(cards[0].topic, 'Primes');
      expect(cards[1].front, 'second');
      expect(cards[1].back, 'other');
    });

    test('accepts Q: and A: as synonyms', () {
      final cards = parseCards('Q: one\nA: uno\n\nQUESTION: two\nANSWER: dos\n');
      expect(cards.map((c) => (c.front, c.back)).toList(),
          [('one', 'uno'), ('two', 'dos')]);
    });

    test('continuation lines join the field last written', () {
      final cards = parseCards('FRONT: Why are\nall Sylow subgroups\nisomorphic?\n'
          'BACK: Conjugation\nis an isomorphism.\n');
      expect(cards.single.front, 'Why are all Sylow subgroups isomorphic?');
      expect(cards.single.back, 'Conjugation is an isomorphism.');
    });

    test('a blank line ends continuation', () {
      final cards = parseCards('FRONT: a\n\nstray line\nBACK: b\n');
      expect(cards.single.front, 'a');
      expect(cards.single.back, 'b');
    });

    test('ignores code fences and chat text around the cards', () {
      final cards = parseCards('Here are your cards:\n\n```\n'
          'FRONT: f\nBACK: b\nTOPIC: T\n```\nGood luck!\n');
      expect(cards.single.front, 'f');
      expect(cards.single.back, 'b');
      expect(cards.single.topic, 'T');
    });

    test('drops a card without a back', () {
      final cards = parseCards('FRONT: no back\n\nFRONT: fine\nBACK: yes\n');
      expect(cards.single.front, 'fine');
    });

    test('no cards gives an empty list', () {
      expect(parseCards('Sorry, nothing to make cards from.'), isEmpty);
      expect(parseCards(''), isEmpty);
    });
  });

  group('splitNotesAndCards', () {
    test('splits the notes from the block, leaving LaTeX alone', () {
      final r = splitNotesAndCards(
          'Notes with \$a<b\$ and \$x\$.\n\n<<<CARDS\nFRONT: x\nBACK: y\nCARDS>>>');
      expect(r.notes, r'Notes with $a<b$ and $x$.');
      expect(r.cards.single.front, 'x');
      expect(r.cards.single.back, 'y');
    });

    test('without a block the whole text is notes', () {
      final r = splitNotesAndCards('  Just notes \$x<y\$  \n');
      expect(r.notes, r'Just notes $x<y$');
      expect(r.cards, isEmpty);
    });

    test('a missing closing marker is tolerated', () {
      final r = splitNotesAndCards('# N\n<<<CARDS\nFRONT: x\nBACK: y\n');
      expect(r.notes, '# N');
      expect(r.cards.single.back, 'y');
    });

    test('uses the last opening marker', () {
      final r = splitNotesAndCards(
          'Mentions <<<CARDS here\n<<<CARDS\nFRONT: x\nBACK: y\nCARDS>>>');
      expect(r.notes, 'Mentions <<<CARDS here');
      expect(r.cards.single.front, 'x');
    });
  });
}
