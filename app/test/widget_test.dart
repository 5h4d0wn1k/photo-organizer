import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_gallery_app/src/app/private_gallery_app.dart';

void main() {
  testWidgets('shows bootstrap progress first', (WidgetTester tester) async {
    await tester.pumpWidget(const PrivateGalleryApp());

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
