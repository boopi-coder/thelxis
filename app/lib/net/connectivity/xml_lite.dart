// A forgiving mini XML reader for UPnP device descriptions and SOAP replies.
//
// Home routers emit sloppy XML (missing end tags, stray ampersands, mixed
// case, odd namespace prefixes), so a strict parser would reject exactly the
// devices we need to talk to. This one never throws: it builds whatever tree
// it can and matches names case-insensitively on the local part (no prefix).

class XmlNode {
  XmlNode(this.name);

  /// Local name without namespace prefix, original case.
  final String name;
  final List<XmlNode> children = [];
  final StringBuffer _text = StringBuffer();

  /// Concatenated character data directly inside this element, trimmed.
  String get text => _text.toString().trim();

  bool _is(String other) => name.toLowerCase() == other.toLowerCase();

  /// Direct child by name.
  XmlNode? child(String childName) {
    for (final c in children) {
      if (c._is(childName)) return c;
    }
    return null;
  }

  /// First descendant (depth-first, document order) by name.
  XmlNode? find(String descendantName) {
    for (final c in children) {
      if (c._is(descendantName)) return c;
      final nested = c.find(descendantName);
      if (nested != null) return nested;
    }
    return null;
  }

  /// All descendants by name, document order.
  Iterable<XmlNode> findAll(String descendantName) sync* {
    for (final c in children) {
      if (c._is(descendantName)) yield c;
      yield* c.findAll(descendantName);
    }
  }

  /// Text of the first descendant called [descendantName], or null.
  String? textOf(String descendantName) => find(descendantName)?.text;
}

const int _maxDepth = 64;

bool _isNameStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x3a;

bool _isNameChar(int c) =>
    _isNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x2e;

String _localName(String qualified) {
  final colon = qualified.indexOf(':');
  return colon < 0 ? qualified : qualified.substring(colon + 1);
}

XmlNode parseXmlLenient(String source) {
  final root = XmlNode('#document');
  final stack = <XmlNode>[root];
  var i = 0;
  final n = source.length;

  void addText(String raw) {
    if (raw.isNotEmpty) stack.last._text.write(_decodeEntities(raw));
  }

  while (i < n) {
    final lt = source.indexOf('<', i);
    if (lt < 0) {
      addText(source.substring(i));
      break;
    }
    if (lt > i) addText(source.substring(i, lt));
    i = lt;

    if (source.startsWith('<!--', i)) {
      final end = source.indexOf('-->', i + 4);
      i = end < 0 ? n : end + 3;
    } else if (source.startsWith('<![CDATA[', i)) {
      final end = source.indexOf(']]>', i + 9);
      final stop = end < 0 ? n : end;
      stack.last._text.write(source.substring(i + 9, stop));
      i = end < 0 ? n : end + 3;
    } else if (source.startsWith('<?', i) || source.startsWith('<!', i)) {
      final end = source.indexOf('>', i + 2);
      i = end < 0 ? n : end + 1;
    } else if (source.startsWith('</', i)) {
      var j = i + 2;
      final start = j;
      while (j < n && _isNameChar(source.codeUnitAt(j))) {
        j++;
      }
      final name = _localName(source.substring(start, j)).toLowerCase();
      final end = source.indexOf('>', j);
      i = end < 0 ? n : end + 1;
      // Pop to the matching open element; ignore closers that match nothing.
      for (var k = stack.length - 1; k > 0; k--) {
        if (stack[k].name.toLowerCase() == name) {
          stack.length = k;
          break;
        }
      }
    } else if (i + 1 < n && _isNameStart(source.codeUnitAt(i + 1))) {
      var j = i + 1;
      final start = j;
      while (j < n && _isNameChar(source.codeUnitAt(j))) {
        j++;
      }
      final node = XmlNode(_localName(source.substring(start, j)));
      // Skip attributes, honouring quotes so a '>' inside a value is safe.
      var selfClosing = false;
      int? quote;
      while (j < n) {
        final c = source.codeUnitAt(j);
        if (quote != null) {
          if (c == quote) quote = null;
        } else if (c == 0x22 || c == 0x27) {
          quote = c;
        } else if (c == 0x3e) {
          selfClosing = j > 0 && source.codeUnitAt(j - 1) == 0x2f;
          j++;
          break;
        }
        j++;
      }
      i = j;
      stack.last.children.add(node);
      // Depth cap: a hostile device could otherwise nest a few hundred
      // thousand unclosed tags and blow the stack in the recursive finders.
      if (!selfClosing && stack.length < _maxDepth) stack.add(node);
    } else {
      // A bare '<' in character data.
      stack.last._text.write('<');
      i++;
    }
  }
  return root;
}

final RegExp _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entity, (m) {
    final body = m.group(1)!;
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
    }
    if (body.startsWith('#x')) {
      final cp = int.tryParse(body.substring(2), radix: 16);
      return cp == null || cp > 0x10ffff
          ? m.group(0)!
          : String.fromCharCode(cp);
    }
    if (body.startsWith('#')) {
      final cp = int.tryParse(body.substring(1));
      return cp == null || cp > 0x10ffff
          ? m.group(0)!
          : String.fromCharCode(cp);
    }
    return m.group(0)!;
  });
}

/// Escapes text for use inside an XML element (SOAP arguments).
String xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
