import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_gallery_app/src/app/private_gallery_app.dart';

void main() {
  testWidgets('shows bootstrap progress first', (WidgetTester tester) async {
    await tester.pumpWidget(
      const PrivateGalleryApp(mode: GalleryClientMode.desktop),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows mobile pairing when mobile mode is selected', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const PrivateGalleryApp(mode: GalleryClientMode.mobile),
    );

    expect(find.text('Pair with desktop'), findsOneWidget);
    expect(find.text('Local-first vault'), findsOneWidget);
  });
}
