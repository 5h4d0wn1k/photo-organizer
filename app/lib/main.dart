import 'package:flutter/material.dart';

import 'src/app/private_gallery_app.dart';
import 'src/services/cloud_bootstrap_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CloudBootstrapService.initializeIfConfigured();
  runApp(const PrivateGalleryApp());
}
