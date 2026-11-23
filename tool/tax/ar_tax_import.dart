// Builds the app's Arkansas sales tax catalog (lib/utils/arkansas_sales_tax_data.dart) from the Arkansas DFA's own
// quarterly "Cities and Counties Tax Rates Table" files (.xls), plus the changes DFA has announced but not yet put in a
// quarterly table (announced_changes.csv).
//
//   dart run tool/tax/ar_tax_import.dart --verified 2026-11-20 <folder or .xls files...>
//
// Each quarterly file lists every city and county with a local sales and use tax, its DFA code, the date its current rate
// took effect and the rate. Several quarters together give each place's rate history: a rate holds from its effective
// date until the next rate's effective date (or until a later quarter drops the place). Nothing is guessed: a place
// is in the catalog only if a DFA table lists it, at the rate the table gives.
//
// The tool checks every city row against the table's own "Total %" column (city + county), resolves every city's
// counties, and prints what changed against the catalog already in the app, so the quarterly update can be reviewed
// before it is published. See docs/arkansas-sales-tax-catalog.md.

import 'dart:io';

import 'xls_reader.dart';

const _out = 'lib/utils/arkansas_sales_tax_data.dart';
const _announced = 'tool/tax/announced_changes.csv';
const _ratesPage =
    'https://www.dfa.arkansas.gov/office/taxes/excise-tax-administration/sales-use-tax/sales-use-tax-rates/city-and-county-sales-use-tax-rates/';
const _changesPage =
    'https://www.dfa.arkansas.gov/office/taxes/excise-tax-administration/sales-use-tax/recent-changes-in-sales-use-tax/recent-changes-for-local-taxes/';
const _statePage = 'https://www.dfa.arkansas.gov/office/taxes/excise-tax-administration/sales-use-tax/sales-use-tax-rates/state-sales-use-tax-rates/';

/// The state rate, from DFA's State Sales & Use Tax Rates page ("State Sales and Use Tax, 07/01/2013, 6.500%").
const _stateMilli = 6500;
const _stateFrom = '2013-07-01';

class _Row {
  final String code, name, from;
  final int milli;
  final List<String> counties; // county names as the table writes them (cities only)
  _Row(this.code, this.name, this.from, this.milli, this.counties);
}

class _Quarter {
  final String start, end, label, file;
  final Map<String, _Row> rows = {};
  _Quarter(this.start, this.end, this.label, this.file);
}

final _problems = <String>[];

void main(List<String> args) {
  String? verified;
  final files = <File>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--verified') {
      verified = args[++i];
    } else if (FileSystemEntity.isDirectorySync(args[i])) {
      files.addAll(Directory(args[i]).listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.xls')));
    } else {
      files.add(File(args[i]));
    }
  }
  if (verified == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(verified) || files.isEmpty) {
    stderr.writeln('usage: dart run tool/tax/ar_tax_import.dart --verified YYYY-MM-DD <folder or .xls files...>');
    exit(64);
  }

  final quarters = [for (final f in files) _readQuarter(f)]..sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < quarters.length; i++) {
    if (quarters[i].start == quarters[i - 1].start) _problems.add('Two files for ${quarters[i].label}: ${quarters[i - 1].file}, ${quarters[i].file}');
  }

  // Each place's rates, in order: (from, milli), and the quarter after which a place was no longer listed.
  final latest = <String, _Row>{};
  final history = <String, Map<String, int>>{}; // code -> from -> milli
  final dropped = <String, String>{}; // code -> first quarter start without it
  for (var qi = 0; qi < quarters.length; qi++) {
    final q = quarters[qi];
    for (final r in q.rows.values) {
      latest[r.code] = r;
      final h = history.putIfAbsent(r.code, () => {});
      final was = h[r.from];
      if (was != null && was != r.milli) {
        _problems.add('${r.name} (${r.code}): ${q.label} lists ${_pct(r.milli)} from ${r.from}, an earlier table ${_pct(was)} from the same date');
      }
      h[r.from] = r.milli;
      dropped.remove(r.code);
    }
    if (qi > 0) {
      for (final code in quarters[qi - 1].rows.keys) {
        if (!q.rows.containsKey(code)) dropped.putIfAbsent(code, () => q.start);
      }
    }
  }

  // Announced changes, after the last table.
  final announced = <String, List<(String, int, String)>>{};
  for (final line in File(_announced).readAsLinesSync().skip(1)) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final f = t.split(',');
    final code = f[0].trim(), from = f[3].trim();
    final milli = (double.parse(f[2]) * 1000).round();
    if (!history.containsKey(code)) {
      _problems.add('Announced change for ${f[1]} ($code) is not a place in any table');
      continue;
    }
    if (from.compareTo(quarters.last.start) <= 0) {
      _problems.add('Announced change for ${f[1]} ($code) from $from is already covered by ${quarters.last.label}: remove it from $_announced');
      continue;
    }
    (announced[code] ??= []).add((from, milli, f.sublist(4).join(',').trim()));
  }

  // County names to codes (for each city's counties).
  final countyCode = <String, String>{};
  for (final r in latest.values.where((r) => r.code.endsWith('-00'))) {
    countyCode[_norm(r.name.replaceFirst(RegExp(r'\s+County$', caseSensitive: false), ''))] = r.code.substring(0, 2);
  }

  final entries = <String>[];
  var cities = 0, counties = 0, zero = 0;
  final codes = latest.keys.toList()..sort();
  for (final code in codes) {
    final r = latest[code]!;
    final county = code.endsWith('-00');
    final periods = <(String, String?, int, bool)>[];
    final froms = history[code]!.keys.toList()..sort();
    for (var i = 0; i < froms.length; i++) {
      final end = i + 1 < froms.length ? _dayBefore(froms[i + 1]) : (dropped[code] == null ? null : _dayBefore(dropped[code]!));
      periods.add((froms[i], end, history[code]![froms[i]]!, false));
    }
    for (final a in announced[code] ?? const <(String, int, String)>[]) {
      final last = periods.removeLast();
      periods.add((last.$1, _dayBefore(a.$1), last.$3, last.$4));
      periods.add((a.$1, null, a.$2, true));
    }
    final countyCodes = county
        ? const <String>[]
        : [
            for (final n in r.counties)
              countyCode[_norm(n)] ??
                  (() {
                    _problems.add('${r.name} ($code): county "$n" is not in the county list');
                    return '??';
                  })(),
          ];
    if (!county && countyCodes.isNotEmpty && countyCodes.first != code.substring(0, 2)) {
      _problems.add('${r.name} ($code): first county ${r.counties.first} is not county ${code.substring(0, 2)}');
    }
    if (county) {
      counties++;
    } else {
      cities++;
    }
    if (periods.last.$3 == 0) zero++;
    final level = county ? 'TaxLevel.county' : 'TaxLevel.city';
    final id = county ? 'AR-${code.substring(0, 2)}' : 'AR-$code';
    final ps = periods.map((p) => "TaxPeriod(${p.$3}, '${p.$1}'${p.$2 == null ? '' : ", to: '${p.$2}'"}${p.$4 ? ', announced: true' : ''})").join(', ');
    entries.add(
      "  TaxJurisdiction('$id', $level, '${_esc(_display(r.name, county))}', '$code', [${countyCodes.map((c) => "'$c'").join(', ')}], [$ps]),",
    );
  }

  final before = File(_out).existsSync() ? File(_out).readAsStringSync() : '';
  final buf = StringBuffer()
    ..writeln('// GENERATED by tool/tax/ar_tax_import.dart. Do not edit by hand: re-run the import (docs/arkansas-sales-tax-catalog.md).')
    ..writeln('//')
    ..writeln('// Source: the Arkansas DFA "Cities and Counties Tax Rates Table", ${quarters.first.label} to ${quarters.last.label}:')
    ..writeln('//   $_ratesPage')
    ..writeln('//   files: ${quarters.map((q) => q.file).join(', ')}')
    ..writeln('// Announced changes not yet in a table ($_announced):')
    ..writeln('//   $_changesPage')
    ..writeln('// State rate: $_statePage')
    ..writeln('// Last verified against DFA: $verified')
    ..writeln()
    ..writeln("part of 'sales_tax_catalog.dart';")
    ..writeln()
    ..writeln('/// Where the catalog comes from and when it was last checked.')
    ..writeln('const kArkansasTaxSource = TaxCatalogSource(')
    ..writeln("  publisher: 'Arkansas Department of Finance and Administration',")
    ..writeln("  table: 'Cities and Counties Tax Rates Table',")
    ..writeln("  firstQuarter: '${quarters.first.label}',")
    ..writeln("  lastQuarter: '${quarters.last.label}',")
    ..writeln("  coversTo: '${quarters.last.end}',")
    ..writeln("  verified: '$verified',")
    ..writeln("  url: '$_ratesPage',")
    ..writeln("  changesUrl: '$_changesPage',")
    ..writeln(');')
    ..writeln()
    ..writeln('/// The state, then every county and city a DFA table lists, by DFA code. Rates are in thousandths of a percent.')
    ..writeln('const kArkansasJurisdictions = <TaxJurisdiction>[')
    ..writeln("  TaxJurisdiction('AR', TaxLevel.state, 'Arkansas', '', [], [TaxPeriod($_stateMilli, '$_stateFrom')]),")
    ..writeAll(entries, '\n')
    ..writeln()
    ..writeln('];');
  File(_out).writeAsStringSync(buf.toString());
  Process.runSync('dart', ['format', '--line-length', '160', _out], runInShell: true);

  stdout.writeln('Quarters: ${quarters.map((q) => '${q.label} (${q.rows.length})').join(', ')}');
  stdout.writeln('Catalog: 1 state, $counties counties, $cities cities ($zero now at 0%), ${announced.length} announced changes.');
  _diff(before, File(_out).readAsStringSync());
  if (_problems.isNotEmpty) {
    stdout.writeln('\nPROBLEMS (${_problems.length}):');
    for (final p in _problems) {
      stdout.writeln('  - $p');
    }
    exitCode = 1;
  } else {
    stdout.writeln('\nNo problems found.');
  }
}

/// One quarterly table.
_Quarter _readQuarter(File f) {
  final sheets = readXls(f.readAsBytesSync());
  final t = sheets.first.table();
  String cell(List<Object?> r, int i) => i < r.length && r[i] != null ? '${r[i]}'.trim() : '';
  // The quarter: "OCTOBER - DECEMBER 2026".
  const months = ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'];
  String? start, end, label;
  for (final r in t) {
    for (final c in r) {
      final m = RegExp(r'^([A-Z]+)\s*[-–]\s*([A-Z]+)\s+(\d{4})$').firstMatch('${c ?? ''}'.trim().toUpperCase());
      if (m != null && months.contains(m[1]) && months.contains(m[2])) {
        final y = int.parse(m[3]!);
        final a = months.indexOf(m[1]!) + 1, b = months.indexOf(m[2]!) + 1;
        start = _iso(DateTime.utc(y, a, 1));
        end = _iso(DateTime.utc(y, b + 1, 1).subtract(const Duration(days: 1)));
        label = '${_title(m[1]!)}–${_title(m[2]!)} $y';
      }
    }
    if (start != null) break;
  }
  if (start == null) throw FormatException('${f.path}: no quarter heading ("OCTOBER - DECEMBER 2026")');
  final q = _Quarter(start, end!, label!, f.uri.pathSegments.last);

  // Columns from the heading row, by their headings: "Name", "Code", "Effective Date", "% Rate" (or "Percentage Rate"),
  // "County Location", then in the newer tables (2025 on) the county's "% Rate" and "Total % Rate". The 2024 tables
  // start with a footnote column ("fn") and have no county rate or total.
  var header = -1;
  for (var i = 0; i < t.length && header < 0; i++) {
    final cells = [for (var c = 0; c < t[i].length; c++) cell(t[i], c).toLowerCase()];
    if (cells.contains('name') && cells.contains('code')) header = i;
  }
  if (header < 0) throw FormatException('${f.path}: no "Name | Code" heading row');
  final heads = [for (var c = 0; c < t[header].length; c++) cell(t[header], c).toLowerCase().replaceAll(RegExp(r'\s+'), ' ')];
  final cName = heads.indexOf('name'), cCode = heads.indexOf('code');
  final cFrom = heads.indexWhere((h) => h.startsWith('effective'));
  final cRate = heads.indexWhere((h) => h.contains('rate'), cFrom + 1);
  final cCounty = heads.indexWhere((h) => h.startsWith('county'));
  final cCountyRate = cCounty < 0 ? -1 : heads.indexWhere((h) => h.contains('rate') && !h.contains('total'), cCounty + 1);
  final cTotal = heads.indexWhere((h) => h.contains('total'));
  if ([cName, cCode, cFrom, cRate, cCounty].any((c) => c < 0)) throw FormatException('${f.path}: unexpected headings $heads');
  var section = '';
  for (final raw in t.skip(header + 1)) {
    // The row's cells in the newer tables' order, wherever this table has them.
    Object? at(int c) => c >= 0 && c < raw.length ? raw[c] : null;
    final r = [at(cName), at(cCode), at(cFrom), at(cRate), at(cCounty), at(cCountyRate), at(cTotal)];
    final sectionMark = [for (final c in raw) '${c ?? ''}'.toUpperCase()].join(' ');
    if (sectionMark.contains('CITY LIST')) {
      section = 'city';
      continue;
    }
    if (sectionMark.contains('COUNTY LIST')) {
      section = 'county';
      continue;
    }
    final name = cell(r, 0).replaceAll(RegExp(r'\s+'), ' ');
    final code = cell(r, 1);
    if (section.isEmpty || name.isEmpty || !RegExp(r'^\d{2}-\d{2}$').hasMatch(code)) continue;
    final from = _date(r.length > 2 ? r[2] : null, '$name ($code) in ${q.file}');
    final rate = r.length > 3 ? r[3] : null;
    if (from == null || rate is! double) {
      _problems.add('$name ($code) in ${q.file}: no effective date or rate');
      continue;
    }
    final milli = (rate * 100000).round();
    final countyRow = code.endsWith('-00');
    if (countyRow != (section == 'county')) _problems.add('$name ($code) in ${q.file}: in the $section list with a ${countyRow ? 'county' : 'city'} code');
    final counties = countyRow ? const <String>[] : cell(r, 4).split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    // A single-county city: the table's own total is the city's rate plus its county's.
    if (!countyRow && counties.length == 1 && r.length > 6 && r[5] is double && r[6] is double) {
      final sum = milli + ((r[5]! as double) * 100000).round();
      final total = ((r[6]! as double) * 100000).round();
      if (sum != total) _problems.add('$name ($code) in ${q.file}: ${_pct(milli)} + county ${_pct(sum - milli)} != total ${_pct(total)}');
    }
    if (q.rows.containsKey(code)) _problems.add('$name ($code) is listed twice in ${q.file}');
    q.rows[code] = _Row(code, name, from, milli, counties);
  }
  return q;
}

String? _date(Object? v, String what) {
  if (v is double) return _iso(DateTime.utc(1899, 12, 30).add(Duration(days: v.round())));
  final s = '${v ?? ''}'.trim();
  final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})$').firstMatch(s);
  if (m == null) return null;
  var y = int.parse(m[3]!);
  if (y < 100) y += y < 70 ? 2000 : 1900;
  return _iso(DateTime.utc(y, int.parse(m[1]!), int.parse(m[2]!)));
}

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _dayBefore(String iso) => _iso(DateTime.parse('${iso}T00:00:00Z').subtract(const Duration(days: 1)));
String _title(String s) => s[0] + s.substring(1).toLowerCase();
String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
String _pct(int milli) => '${(milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '')}%';
String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

/// A place's name as the app shows it: "Benton" for "Benton (city)" (the list it is in already says it is a city),
/// tidy capitals for a name the table wrote in capitals.
String _display(String name, bool county) {
  var n = name.replaceAll(RegExp(r'\s*\((city|CITY|City)\)\s*$'), '').trim();
  if (n == n.toUpperCase()) n = n.split(' ').map((w) => w.isEmpty ? w : w[0] + w.substring(1).toLowerCase()).join(' ');
  return n;
}

/// What changed against the catalog already in the app, line by line, so the update can be reviewed.
void _diff(String before, String after) {
  if (before.isEmpty) {
    stdout.writeln('\nNo earlier catalog: everything is new.');
    return;
  }
  Map<String, String> byId(String s) => {
    for (final m in RegExp(r"TaxJurisdiction\('([^']+)'.*\),\s*$", multiLine: true).allMatches(s)) m[1]!: m[0]!.trim(),
  };
  final a = byId(before), b = byId(after);
  final added = b.keys.where((k) => !a.containsKey(k)).toList();
  final gone = a.keys.where((k) => !b.containsKey(k)).toList();
  final changed = b.keys.where((k) => a.containsKey(k) && a[k] != b[k]).toList();
  stdout.writeln('\nAgainst the catalog in the app: ${added.length} added, ${gone.length} removed, ${changed.length} changed.');
  for (final k in added) {
    stdout.writeln('  + ${b[k]}');
  }
  for (final k in gone) {
    stdout.writeln('  - ${a[k]}');
  }
  for (final k in changed) {
    stdout.writeln('  ~ was ${a[k]}\n         ${b[k]}');
  }
}
