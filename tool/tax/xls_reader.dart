// A small reader for the old Excel format (.xls, BIFF8 in an OLE2 compound file), enough to read the DFA's quarterly
// "Cities and Counties Tax Rates Table": the text and number cells of each sheet. No package needed, so the tax import
// (ar_tax_import.dart) runs with the Dart SDK alone.
//
// Handled: the compound file's FAT chains, the Workbook stream, the shared strings (SST, across CONTINUE records),
// LABELSST, LABEL, NUMBER, RK, MULRK and FORMULA (number and string results). Anything else is skipped.

import 'dart:convert';
import 'dart:typed_data';

class XlsSheet {
  final String name;

  /// Cells by row, then column: a String or a double.
  final Map<int, Map<int, Object>> rows = {};
  XlsSheet(this.name);

  void put(int r, int c, Object v) => (rows[r] ??= {})[c] = v;

  /// The rows in order, each as a list of cells (null where empty), [width] wide.
  List<List<Object?>> table() {
    final width = rows.values.fold<int>(0, (m, r) => r.keys.fold(m, (a, b) => b + 1 > a ? b + 1 : a));
    final keys = rows.keys.toList()..sort();
    return [
      for (final k in keys) [for (var c = 0; c < width; c++) rows[k]![c]],
    ];
  }
}

List<XlsSheet> readXls(Uint8List bytes) {
  final wb = _workbookStream(bytes);
  return _parseBiff(wb);
}

// ---- OLE2 compound file ---------------------------------------------------------------------------------------------

Uint8List _workbookStream(Uint8List b) {
  final d = ByteData.sublistView(b);
  const magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  for (var i = 0; i < 8; i++) {
    if (b[i] != magic[i]) throw const FormatException('Not an .xls file (no OLE2 header)');
  }
  final sectorSize = 1 << d.getUint16(30, Endian.little);
  final miniSize = 1 << d.getUint16(32, Endian.little);
  final fatSectors = d.getUint32(44, Endian.little);
  final dirStart = d.getUint32(48, Endian.little);
  final miniCutoff = d.getUint32(56, Endian.little);
  final miniFatStart = d.getUint32(60, Endian.little);
  var difatStart = d.getUint32(68, Endian.little);
  int off(int sector) => (sector + 1) * sectorSize;

  // The FAT's own sectors: 109 in the header, the rest in the DIFAT chain.
  final fatList = <int>[];
  for (var i = 0; i < 109 && fatList.length < fatSectors; i++) {
    fatList.add(d.getUint32(76 + i * 4, Endian.little));
  }
  while (fatList.length < fatSectors && difatStart < 0xFFFFFFFA) {
    final o = off(difatStart);
    final per = sectorSize ~/ 4 - 1;
    for (var i = 0; i < per && fatList.length < fatSectors; i++) {
      fatList.add(d.getUint32(o + i * 4, Endian.little));
    }
    difatStart = d.getUint32(o + per * 4, Endian.little);
  }
  final fat = <int>[];
  for (final s in fatList) {
    final o = off(s);
    for (var i = 0; i < sectorSize ~/ 4; i++) {
      fat.add(d.getUint32(o + i * 4, Endian.little));
    }
  }
  Uint8List chain(int start, {int? size}) {
    final out = BytesBuilder(copy: false);
    var s = start;
    var guard = 0;
    while (s < 0xFFFFFFFA && guard++ < fat.length + 1) {
      final o = off(s);
      out.add(Uint8List.sublistView(b, o, (o + sectorSize).clamp(0, b.length)));
      s = fat[s];
    }
    final all = out.takeBytes();
    return size == null || size > all.length ? all : Uint8List.sublistView(all, 0, size);
  }

  final dir = chain(dirStart);
  final dd = ByteData.sublistView(dir);
  Uint8List? root;
  for (var e = 0; e + 128 <= dir.length; e += 128) {
    final nameLen = dd.getUint16(e + 64, Endian.little);
    if (nameLen < 2) continue;
    final name = String.fromCharCodes([for (var i = 0; i < nameLen - 2; i += 2) dd.getUint16(e + i, Endian.little)]);
    final type = dir[e + 66];
    final start = dd.getUint32(e + 116, Endian.little);
    final size = dd.getUint32(e + 120, Endian.little);
    if (type == 5) root = chain(start); // the root entry holds the mini stream
    if (name == 'Workbook' || name == 'Book') {
      if (size >= miniCutoff) return chain(start, size: size);
      // A small workbook lives in the mini stream.
      final miniFat = <int>[];
      final mf = chain(miniFatStart);
      for (var i = 0; i + 4 <= mf.length; i += 4) {
        miniFat.add(ByteData.sublistView(mf).getUint32(i, Endian.little));
      }
      final out = BytesBuilder(copy: false);
      var s = start;
      while (s < 0xFFFFFFFA && root != null) {
        out.add(Uint8List.sublistView(root, s * miniSize, s * miniSize + miniSize));
        s = miniFat[s];
      }
      return Uint8List.sublistView(out.takeBytes(), 0, size);
    }
  }
  throw const FormatException('No Workbook stream in the .xls file');
}

// ---- BIFF8 ----------------------------------------------------------------------------------------------------------

List<XlsSheet> _parseBiff(Uint8List w) {
  final d = ByteData.sublistView(w);
  final sheets = <XlsSheet>[];
  final sheetNames = <String>[];
  final sst = <String>[];
  XlsSheet? current;
  var depth = 0;
  var pos = 0;
  int? pendingRow, pendingCol; // a FORMULA whose string result comes in the next STRING record

  while (pos + 4 <= w.length) {
    final type = d.getUint16(pos, Endian.little);
    final len = d.getUint16(pos + 2, Endian.little);
    final start = pos + 4;
    final end = start + len;
    if (end > w.length) break;

    switch (type) {
      case 0x0809: // BOF
        depth++;
        final kind = d.getUint16(start + 2, Endian.little);
        if (kind == 0x0010 && sheets.length < sheetNames.length) {
          current = XlsSheet(sheetNames[sheets.length]);
          sheets.add(current);
        }
      case 0x000A: // EOF
        depth--;
        if (depth <= 1) current = null;
      case 0x0085: // BOUNDSHEET
        final n = w[start + 6];
        final flags = w[start + 7];
        sheetNames.add(_chars(w, start + 8, n, (flags & 1) == 1));
      case 0x00FC: // SST (and its CONTINUE records)
        final parts = <Uint8List>[Uint8List.sublistView(w, start, end)];
        var p = end;
        while (p + 4 <= w.length && d.getUint16(p, Endian.little) == 0x003C) {
          final l = d.getUint16(p + 2, Endian.little);
          parts.add(Uint8List.sublistView(w, p + 4, p + 4 + l));
          p += 4 + l;
        }
        sst.addAll(_readSst(parts));
        pos = p;
        continue;
      case 0x00FD: // LABELSST
        final r = d.getUint16(start, Endian.little), c = d.getUint16(start + 2, Endian.little);
        final i = d.getUint32(start + 6, Endian.little);
        if (i < sst.length) current?.put(r, c, sst[i]);
      case 0x0204: // LABEL
        final r = d.getUint16(start, Endian.little), c = d.getUint16(start + 2, Endian.little);
        final n = d.getUint16(start + 6, Endian.little);
        final flags = w[start + 8];
        current?.put(r, c, _chars(w, start + 9, n, (flags & 1) == 1));
      case 0x0203: // NUMBER
        final r = d.getUint16(start, Endian.little), c = d.getUint16(start + 2, Endian.little);
        current?.put(r, c, d.getFloat64(start + 6, Endian.little));
      case 0x027E: // RK
        final r = d.getUint16(start, Endian.little), c = d.getUint16(start + 2, Endian.little);
        current?.put(r, c, _rk(d.getUint32(start + 6, Endian.little)));
      case 0x00BD: // MULRK
        final r = d.getUint16(start, Endian.little);
        final first = d.getUint16(start + 2, Endian.little);
        final count = (len - 6) ~/ 6;
        for (var k = 0; k < count; k++) {
          current?.put(r, first + k, _rk(d.getUint32(start + 4 + k * 6 + 2, Endian.little)));
        }
      case 0x0006: // FORMULA
        final r = d.getUint16(start, Endian.little), c = d.getUint16(start + 2, Endian.little);
        final isOther = w[start + 12] == 0xFF && w[start + 13] == 0xFF;
        if (!isOther) {
          current?.put(r, c, d.getFloat64(start + 6, Endian.little));
        } else if (w[start + 6] == 0) {
          pendingRow = r;
          pendingCol = c;
        }
      case 0x0207: // STRING (a formula's text result)
        if (pendingRow != null && pendingCol != null) {
          final n = d.getUint16(start, Endian.little);
          final flags = w[start + 2];
          current?.put(pendingRow, pendingCol, _chars(w, start + 3, n, (flags & 1) == 1));
        }
        pendingRow = pendingCol = null;
    }
    pos = end;
  }
  return sheets;
}

double _rk(int v) {
  final div100 = (v & 1) == 1;
  final isInt = (v & 2) == 2;
  double n;
  if (isInt) {
    n = (v >> 2).toSigned(30).toDouble();
  } else {
    final bd = ByteData(8)..setUint32(4, v & 0xFFFFFFFC, Endian.little);
    n = bd.getFloat64(0, Endian.little);
  }
  return div100 ? n / 100 : n;
}

String _chars(Uint8List w, int at, int n, bool wide) {
  if (wide) {
    final d = ByteData.sublistView(w);
    return String.fromCharCodes([for (var i = 0; i < n; i++) d.getUint16(at + i * 2, Endian.little)]);
  }
  return latin1.decode(Uint8List.sublistView(w, at, at + n));
}

/// The shared strings, read across the SST record and its CONTINUE records. A string's characters can run on into the
/// next record, which then starts with a fresh option byte saying whether they are one or two bytes each.
List<String> _readSst(List<Uint8List> parts) {
  var part = 0, p = 0;
  Uint8List cur = parts[0];
  int u8() {
    if (p >= cur.length) {
      part++;
      cur = parts[part];
      p = 0;
    }
    return cur[p++];
  }

  int u16() => u8() | (u8() << 8);
  int u32() => u16() | (u16() << 16);
  void skip(int n) {
    for (var i = 0; i < n; i++) {
      u8();
    }
  }

  u32(); // total
  final unique = u32();
  final out = <String>[];
  for (var s = 0; s < unique; s++) {
    final n = u16();
    var flags = u8();
    final rich = (flags & 0x08) != 0, ext = (flags & 0x04) != 0;
    final runs = rich ? u16() : 0;
    final extLen = ext ? u32() : 0;
    var wide = (flags & 1) == 1;
    final codes = <int>[];
    while (codes.length < n) {
      if (p >= cur.length) {
        // The characters continue in the next record, after its own option byte.
        part++;
        cur = parts[part];
        p = 0;
        flags = u8();
        wide = (flags & 1) == 1;
      }
      codes.add(wide ? u16() : u8());
    }
    out.add(String.fromCharCodes(codes));
    skip(runs * 4 + extLen);
  }
  return out;
}
