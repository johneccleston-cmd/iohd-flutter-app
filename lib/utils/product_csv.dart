import 'dart:convert';
import 'dart:typed_data';

import '../services/line_items_api.dart';

/// The Product Catalog as a spreadsheet file (CSV): one row per product, in the order given. The cost column is left
/// out when the person's Line Items & Costs > View switch is off, as it is on screen.
String productCatalogCsv(List<CatalogEntry> products, {required bool canSeeCost}) {
  final headers = ['Product', 'Part #', 'Category', 'Model', 'In stock', if (canSeeCost) 'Unit cost', 'Price', 'Member price', 'Status', 'Inventory item'];
  final out = StringBuffer()..write(_line(headers));
  for (final e in products) {
    out.write(
      _line([
        e.name,
        e.sku,
        e.category,
        e.model,
        e.stock == null ? '' : '${e.stock}',
        if (canSeeCost) _money(e.cost),
        _money(e.rate), // blank means priced per job
        _money(e.memberPrice),
        e.active ? 'Active' : 'Inactive',
        e.inInventory ? 'Yes' : 'No',
      ]),
    );
  }
  return out.toString();
}

/// The file's bytes: UTF-8 with a byte order mark, so Excel reads the accents and symbols right.
Uint8List productCatalogCsvBytes(String csv) => Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);

String _money(double? v) => v == null ? '' : v.toStringAsFixed(2);

String _line(List<String> cells) => '${cells.map(_cell).join(',')}\r\n';

String _cell(String v) {
  // A text cell a spreadsheet would read as a formula gets a quote in front, so opening the file never runs anything.
  var t = v;
  if (t.isNotEmpty && '=+@\t\r'.contains(t[0])) t = "'$t";
  if (t.contains(RegExp(r'[",\r\n]'))) t = '"${t.replaceAll('"', '""')}"';
  return t;
}
