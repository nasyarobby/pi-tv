import 'dart:convert';
import 'dart:io';

import 'log.dart';

/// Tiny JSON file persistence (queue, history, sessions).
class JsonStore {
  JsonStore(this.path);
  final String? path;
  final _log = Log('store');

  Object? read() {
    final p = path;
    if (p == null) return null;
    final f = File(p);
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync());
    } catch (e) {
      _log.warn('ignoring unreadable $p: $e');
      return null;
    }
  }

  void write(Object? value) {
    final p = path;
    if (p == null) return;
    try {
      final f = File(p);
      f.parent.createSync(recursive: true);
      final tmp = File('$p.tmp');
      tmp.writeAsStringSync(jsonEncode(value));
      tmp.renameSync(p);
    } catch (e) {
      _log.warn('could not write $p: $e');
    }
  }
}
