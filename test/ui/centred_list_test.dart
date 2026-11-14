import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnmath/ui/widgets.dart';

void main() {
  Future<void> pump(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CentredListView(
          maxWidth: 640,
          padding: const EdgeInsets.all(16),
          children: [
            for (var i = 0; i < 40; i++)
              SizedBox(height: 80, child: Text('row $i')),
          ],
        ),
      ),
    ));
  }

  testWidgets('on a tablet the blank margins scroll the list', (tester) async {
    await pump(tester, 2000);
    final first = tester.getTopLeft(find.text('row 0'));
    // Content is a 640 wide column (less its padding) in the middle.
    expect(first.dx, (2000 - 640) / 2 + 16);
    expect(tester.getSize(find.text('row 0').first).width,
        lessThanOrEqualTo(640 - 32));

    // Far left and far right of the screen, well outside the column.
    await tester.dragFrom(const Offset(40, 600), const Offset(0, -300));
    await tester.pump();
    final afterLeft = tester.getTopLeft(find.text('row 4')).dy;
    await tester.dragFrom(const Offset(1960, 600), const Offset(0, -300));
    await tester.pump();
    expect(find.text('row 0'), findsNothing);
    expect(tester.getTopLeft(find.text('row 8')).dy, lessThan(afterLeft + 320));
  });

  testWidgets('on a phone the padding is unchanged', (tester) async {
    await pump(tester, 400);
    expect(tester.getTopLeft(find.text('row 0')).dx, 16);
  });

  test('centredPadding', () {
    const p = EdgeInsets.fromLTRB(16, 0, 16, 32);
    expect(centredPadding(500, p, 640), p);
    expect(centredPadding(1000, p, 640),
        const EdgeInsets.fromLTRB(196, 0, 196, 32));
  });
}
