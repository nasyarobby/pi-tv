import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pi_tv_shared/pi_tv_shared.dart';

/// Six digit numeric keypad with large keys. Hardware digit keys work too
/// (web / emulator). Calls [onCompleted] once six digits are entered.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onCompleted, this.enabled = true});
  final ValueChanged<String> onCompleted;
  final bool enabled;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _digits = '';
  final _focus = FocusNode();

  void clear() => setState(() => _digits = '');

  void _add(String d) {
    if (!widget.enabled || _digits.length >= pinLength) return;
    setState(() => _digits += d);
    if (_digits.length == pinLength) widget.onCompleted(_digits);
  }

  void _back() {
    if (!widget.enabled || _digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final ch = e.character;
    if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) {
      _add(ch);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, {VoidCallback? onTap, Widget? child, String? semantics}) => Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 84,
            height: 72,
            child: FilledButton.tonal(
              key: ValueKey('pin-key-$label'),
              onPressed: widget.enabled ? onTap : null,
              style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), padding: EdgeInsets.zero),
              child: Semantics(
                  label: semantics ?? label,
                  child: child ?? Text(label, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w500))),
            ),
          ),
        );

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < pinLength; i++)
                Container(
                  key: ValueKey('pin-dot-$i'),
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 20),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _digits.length ? scheme.primary : Colors.transparent,
                    border: Border.all(color: scheme.primary, width: 2),
                  ),
                ),
            ],
          ),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, onTap: () => _add(d))]),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 96),
              key('0', onTap: () => _add('0')),
              key('back', onTap: _back, child: const Icon(Icons.backspace_outlined, size: 28), semantics: 'Delete'),
            ],
          ),
        ],
      ),
    );
  }
}
