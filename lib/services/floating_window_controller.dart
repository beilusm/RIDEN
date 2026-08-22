import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/app_theme.dart';

/// Owns the desktop floating-window state and native window transitions.
///
/// The floating view is still part of the same Flutter application, so it
/// keeps the existing provider, stream and serial lifecycle intact.  Only the
/// native window chrome and the visible shell change.
class FloatingWindowController extends ChangeNotifier {
  bool _isFloating = false;
  bool get isFloating => _isFloating;
  bool _transitioning = false;
  bool _locked = false;
  bool get locked => _locked;

  bool showVoltage = true;
  bool showCurrent = true;
  bool showPower = true;
  bool showChart = true;
  double opacity = 0.94;

  bool get supported => Platform.isWindows || Platform.isLinux;

  Future<void> enter() async {
    if (!supported || _isFloating || _transitioning) return;
    _transitioning = true;

    try {
      await windowManager.setAsFrameless();
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      // Clear constraints inherited from the normal dashboard before
      // applying the HUD bounds. GTK/Wayland otherwise keeps the old
      // dashboard geometry when the decoration is removed.
      await _clearWindowConstraints();
      await windowManager.setResizable(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Set the smaller bounds before resizing. On Windows the plugin ignores
      // negative sizes, so the normal dashboard minimum would otherwise still
      // constrain this first floating-window resize.
      await windowManager.setMinimumSize(_minimumFloatingSize);
      await windowManager.setSize(_floatingSize);
      await windowManager.setMaximumSize(const Size(1600, 1000));
      // Keep the native resize hint enabled on both desktop platforms. The
      // HUD owns the actual drag/resize hit areas, while changing the native
      // hint during a frameless transition can make the compositor replace
      // the current bounds with the widget's natural size.
      await windowManager.setResizable(true);
      if (Platform.isWindows) {
        await windowManager.setHasShadow(true);
      }
      await windowManager.setOpacity(opacity);
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();

      _isFloating = true;
      notifyListeners();
    } finally {
      _transitioning = false;
    }
  }

  Future<void> exit() async {
    if (!supported || !_isFloating || _transitioning) return;
    _transitioning = true;

    try {
      _isFloating = false;
      notifyListeners();

      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await _clearWindowConstraints();
      await windowManager.setResizable(true);
      await windowManager.setOpacity(1.0);
      await windowManager.setBackgroundColor(AppTheme.bgDarkest);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setMinimumSize(const Size(1024, 640));
      await windowManager.setSize(const Size(1360, 800));
      await windowManager.center();
      await windowManager.focus();
    } finally {
      _transitioning = false;
    }
  }

  Future<void> toggle() => _isFloating ? exit() : enter();

  Future<void> applySettings({
    required bool voltage,
    required bool current,
    required bool power,
    required bool chart,
    required double windowOpacity,
  }) async {
    showVoltage = voltage;
    showCurrent = current;
    showPower = power;
    showChart = chart;
    opacity = windowOpacity.clamp(0.55, 1.0);

    if (_isFloating) {
      await windowManager.setOpacity(opacity);
      await windowManager.setMinimumSize(_minimumFloatingSize);
      await windowManager.setSize(_floatingSize);
    }
    notifyListeners();
  }

  Future<void> setLocked(bool value) async {
    _locked = value;
    // Locking is implemented by removing the drag/resize hit areas in
    // FloatingOverlay. Keep the native resize hint unchanged: toggling it on
    // a frameless window can resize the window unexpectedly on desktop.
    notifyListeners();
  }

  Future<void> toggleLocked() => setLocked(!_locked);

  Future<void> _clearWindowConstraints() async {
    if (Platform.isWindows) {
      // window_manager's Windows backend ignores negative sizes. Use a
      // practical desktop-sized range to release the normal dashboard hints.
      await windowManager.setMinimumSize(Size.zero);
      await windowManager.setMaximumSize(const Size(100000, 100000));
    } else {
      await windowManager.setMinimumSize(const Size(-1, -1));
      await windowManager.setMaximumSize(const Size(-1, -1));
    }
  }

  Size get _floatingSize {
    final metricCount = [
      showVoltage,
      showCurrent,
      showPower,
    ].where((visible) => visible).length;
    final metricHeight = metricCount == 0
        ? 48.0
        : (metricCount <= 2 ? 112.0 : 164.0);
    return Size(520, metricHeight + (showChart ? 148 : 0) + 58);
  }

  Size get _minimumFloatingSize => Size(260, showChart ? 150 : 105);
}
