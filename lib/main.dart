library nondesu;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:http/http.dart' as http;
import 'package:webfeed/webfeed.dart' as wf;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:audioplayers/audioplayers.dart';

part 'src/app.dart';
part 'src/models.dart';
part 'src/home.dart';
part 'src/ui_widgets.dart';
part 'src/dedupe.dart';
part 'src/fingerprint.dart';
part 'src/rss_models.dart';
part 'src/avatar_picker.dart';
part 'src/tts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // acrylic init first
  await Window.initialize();

  // Window init
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(360, 520),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    alwaysOnTop: true,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // フレーム/影を消す
    await windowManager.setAsFrameless();      // outline border等を除去
    await windowManager.setHasShadow(false);   // Windowsではframeless時にだけ効く

    await Window.setWindowBackgroundColorToClear();
    await Window.makeTitlebarTransparent();
    await Window.addEmptyMaskImage();
    await Window.disableShadow();

    // 影は念のためこちらも（flutter_acrylic側）
    try { Window.disableShadow(); } catch (_) {}

    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MascotApp());
}
