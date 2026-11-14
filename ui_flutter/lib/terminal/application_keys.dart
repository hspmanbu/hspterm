import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// UI routing only. SSH key encoding remains in the original Rust terminal.
class PaletteBinding {
  const PaletteBinding({
    this.enabled = true,
    this.key = LogicalKeyboardKey.keyP,
    this.modifiers = 5,
    this.applicationInTerminal = false,
  });
  final bool enabled, applicationInTerminal;
  final LogicalKeyboardKey key;
  final int modifiers;
  static final keys = Map<String, LogicalKeyboardKey>.unmodifiable({
    for (var i = 0; i < 26; i++)
      'Key${String.fromCharCode(65 + i)}': LogicalKeyboardKey(97 + i),
    for (var i = 0; i < 10; i++) 'Digit$i': LogicalKeyboardKey(48 + i),
    'F1': LogicalKeyboardKey.f1,
    'F2': LogicalKeyboardKey.f2,
    'F3': LogicalKeyboardKey.f3,
    'F4': LogicalKeyboardKey.f4,
    'F5': LogicalKeyboardKey.f5,
    'F6': LogicalKeyboardKey.f6,
    'F7': LogicalKeyboardKey.f7,
    'F8': LogicalKeyboardKey.f8,
    'F9': LogicalKeyboardKey.f9,
    'F10': LogicalKeyboardKey.f10,
    'F11': LogicalKeyboardKey.f11,
    'F12': LogicalKeyboardKey.f12,
  });
  bool matches(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed) return false;
    final mods =
        (keyboard.isShiftPressed ? 1 : 0) |
        (keyboard.isAltPressed ? 2 : 0) |
        (keyboard.isControlPressed ? 4 : 0);
    return enabled && event.logicalKey == key && mods == modifiers;
  }
}

/// Wraps the Navigator so owned key releases remain local even when a dialog
/// opens/closes between key-down and key-up. Never receives text/IME commits.
class ApplicationKeyScope extends StatefulWidget {
  const ApplicationKeyScope({
    super.key,
    required this.binding,
    required this.openPalette,
    required this.child,
  });
  final PaletteBinding binding;
  final Future<void> Function() openPalette;
  final Widget child;
  static KeyEventResult terminal(
    BuildContext context,
    KeyEvent event, {
    required bool composing,
  }) =>
      context.getInheritedWidgetOfExactType<_KeyOwner>()?.owner.terminal(
        event,
        composing,
      ) ??
      KeyEventResult.ignored;

  /// Keep a modifier release with the SSH session that received its press,
  /// even if a local dialog or a different tab owns focus when it is released.
  static void forwardedModifier(
    BuildContext context,
    KeyEvent event,
    void Function(KeyEvent) release,
  ) {
    if (event is KeyDownEvent) {
      context
              .getInheritedWidgetOfExactType<_KeyOwner>()
              ?.owner
              ._remoteModifiers[event.physicalKey] =
          release;
    }
  }

  static void Function(KeyEvent)? claimHandler(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_KeyOwner>()?.owner.claim;

  /// A local dialog action owns its own release, including Enter/Escape, so
  /// it cannot become an orphan Kitty release after terminal focus returns.
  static void claim(BuildContext context, KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      context.getInheritedWidgetOfExactType<_KeyOwner>()?.owner.claim(event);
    }
  }

  @override
  State<ApplicationKeyScope> createState() => _ApplicationKeyScopeState();
}

class _KeyOwner extends InheritedWidget {
  const _KeyOwner({required this.owner, required super.child});
  final _ApplicationKeyScopeState owner;
  @override
  bool updateShouldNotify(_KeyOwner oldWidget) => false;
}

class _ApplicationKeyScopeState extends State<ApplicationKeyScope> {
  final _owned = <PhysicalKeyboardKey>{};
  final _terminalEvents = Expando<bool>();
  final _remoteModifiers = <PhysicalKeyboardKey, void Function(KeyEvent)>{};
  final _remoteReleases = Expando<bool>();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_releaseModifier);
  }

  bool _releaseModifier(KeyEvent event) {
    if (_remoteReleases[event] == true) return true;
    if (event is! KeyUpEvent) return false;
    final release = _remoteModifiers.remove(event.physicalKey);
    if (release == null) return false;
    _remoteReleases[event] = true;
    release(event);
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_releaseModifier);
    _remoteModifiers.clear();
    super.dispose();
  }

  void claim(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _owned.add(event.physicalKey);
    }
  }

  KeyEventResult terminal(KeyEvent event, bool composing) {
    _terminalEvents[event] = true;
    if (_releaseModifier(event)) return KeyEventResult.handled;
    return _route(event, terminal: true, composing: composing);
  }

  KeyEventResult _route(
    KeyEvent event, {
    required bool terminal,
    bool composing = false,
  }) {
    if (event is KeyUpEvent && _owned.remove(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent && _owned.contains(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editable =
        focusContext?.findAncestorStateOfType<EditableTextState>() != null;
    if (event.logicalKey == LogicalKeyboardKey.space &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        (!terminal && editable)) {
      // Leave native WM_CHAR/IME delivery enabled, but stop the ancestor's
      // ActivateIntent. Space on an actual button continues to activate it.
      return KeyEventResult.skipRemainingHandlers;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // A fresh down supersedes ownership left by a lost platform key-up.
    _owned.remove(event.physicalKey);
    if (composing ||
        (terminal && !widget.binding.applicationInTerminal) ||
        !widget.binding.matches(event)) {
      return KeyEventResult.ignored;
    }
    claim(event);
    unawaited(widget.openPalette());
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => _KeyOwner(
    owner: this,
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) => _terminalEvents[event] == true
          ? KeyEventResult.ignored
          : _route(event, terminal: false),
      child: widget.child,
    ),
  );
}
