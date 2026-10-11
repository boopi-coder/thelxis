import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../session/hid.dart';
import '../../session/input_encoder.dart';

/// Sentinel kept in the hidden field so Backspace on an "empty" field still
/// produces a text change we can detect.
const String kSoftKeyboardSentinel = '​';

/// Result of diffing the field text against the previous content.
class SoftKeyboardDelta {
  const SoftKeyboardDelta({this.backspaces = 0, this.text = ''});
  final int backspaces;
  final String text;
}

/// Turns a change of the hidden field's content into key presses and text.
/// [previous] is what the field held before (including the sentinel).
SoftKeyboardDelta diffSoftKeyboard(String previous, String current) {
  final prev = previous.replaceAll(kSoftKeyboardSentinel, '');
  final cur = current.replaceAll(kSoftKeyboardSentinel, '');
  if (current.isEmpty && previous.isNotEmpty && cur.isEmpty && prev.isEmpty) {
    // Sentinel deleted: a Backspace on empty input.
    return const SoftKeyboardDelta(backspaces: 1);
  }
  var common = 0;
  while (common < prev.length && common < cur.length && prev[common] == cur[common]) {
    common++;
  }
  return SoftKeyboardDelta(
    backspaces: prev.length - common,
    text: cur.substring(common),
  );
}

/// An (almost) invisible text field that summons the Android soft keyboard
/// and forwards what is typed: characters as `txt`, Backspace and Enter as
/// HID key presses.
class SoftKeyboardField extends StatefulWidget {
  const SoftKeyboardField({super.key, required this.encoder, required this.onClosed});

  final InputEncoder encoder;
  final VoidCallback onClosed;

  @override
  State<SoftKeyboardField> createState() => _SoftKeyboardFieldState();
}

class _SoftKeyboardFieldState extends State<SoftKeyboardField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  String _previous = kSoftKeyboardSentinel;

  @override
  void initState() {
    super.initState();
    _reset();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onClosed();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _reset() {
    _previous = kSoftKeyboardSentinel;
    _controller.value = const TextEditingValue(
      text: kSoftKeyboardSentinel,
      selection: TextSelection.collapsed(offset: 1),
    );
  }

  void _onChanged(String value) {
    final d = diffSoftKeyboard(_previous, value);
    for (var i = 0; i < d.backspaces; i++) {
      widget.encoder.tapKey(Hid.backspace);
    }
    if (d.text.isNotEmpty) widget.encoder.text(d.text);
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.01,
      child: SizedBox(
        width: 8,
        height: 8,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          textInputAction: TextInputAction.send,
          onChanged: _onChanged,
          onSubmitted: (_) {
            widget.encoder.tapKey(Hid.enter);
            _reset();
            _focus.requestFocus();
          },
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp('\u0000')),
          ],
        ),
      ),
    );
  }
}
