// The discounts and fees the Tax, discounts & fees panel offers, and the out-of-state tax's starting label and rate.
// Edited on the Tax, Discounts & Fees screen (Inventory menu) and kept by the server; the built-in list below is what
// the panel offers until anything has been saved there (or while the server can't be reached).
//
// The built-in names are Service Fusion's own, as the office has used them on jobs since 2025 (checked on production
// 2026-11-20): Credit Card Convenience Fee (3%) is the only fee Service Fusion has; the discounts are its commonest,
// each with the kind it is usually entered as. No starting amount is guessed, except where the name says it ($45 Same
// Day Service Credit) or Service Fusion always uses one (the card fee's 3%).

/// A discount or fee is a percentage or a dollar amount.
enum ChargeMode { percent, amount }

class ChargePreset {
  final String id;

  /// A fee (added on) rather than a discount (taken off).
  final bool fee;
  final String name;
  final ChargeMode mode;

  /// The starting percentage or dollar amount, or null to have it typed each time.
  final double? value;

  /// Offered in the panel. A preset that is switched off stays here (and on any record it was used on).
  final bool active;
  const ChargePreset({required this.id, required this.fee, required this.name, required this.mode, this.value, this.active = true});

  ChargePreset copyWith({String? name, ChargeMode? mode, Object? value = _keep, bool? active}) => ChargePreset(
    id: id,
    fee: fee,
    name: name ?? this.name,
    mode: mode ?? this.mode,
    value: identical(value, _keep) ? this.value : (value as num?)?.toDouble(),
    active: active ?? this.active,
  );

  static const _keep = Object();

  factory ChargePreset.fromJson(Map<String, dynamic> j) => ChargePreset(
    id: (j['id'] ?? '').toString(),
    fee: j['fee'] == true,
    name: (j['name'] ?? '').toString().trim(),
    mode: j['mode'] == 'amount' ? ChargeMode.amount : ChargeMode.percent,
    value: j['value'] is num ? (j['value'] as num).toDouble() : double.tryParse('${j['value'] ?? ''}'),
    active: j['active'] != false,
  );

  Map<String, dynamic> toJson() => {'id': id, 'fee': fee, 'name': name, 'mode': mode.name, 'value': value, 'active': active};

  bool sameAs(ChargePreset o) => id == o.id && fee == o.fee && name == o.name && mode == o.mode && value == o.value && active == o.active;
}

/// A rate change typed in on the Tax, Discounts & Fees screen for an Arkansas place, from a day on: one DFA has
/// announced that the app's catalog doesn't have yet. It is used from [from] until the catalog is updated.
class TaxRateChange {
  final String jurisdictionId;
  final int milli;
  final String from;
  final String note;
  const TaxRateChange({required this.jurisdictionId, required this.milli, required this.from, this.note = ''});

  factory TaxRateChange.fromJson(Map<String, dynamic> j) => TaxRateChange(
    jurisdictionId: (j['jurisdictionId'] ?? '').toString(),
    milli: j['milli'] is num ? (j['milli'] as num).round() : int.tryParse('${j['milli'] ?? ''}') ?? 0,
    from: (j['from'] ?? '').toString(),
    note: (j['note'] ?? '').toString(),
  );

  Map<String, dynamic> toJson() => {'jurisdictionId': jurisdictionId, 'milli': milli, 'from': from, 'note': note};
}

/// Everything the Tax, Discounts & Fees screen edits.
class TaxSettings {
  final List<ChargePreset> presets;
  final String outOfStateLabel;

  /// The out-of-state tax's starting rate, or null to have it typed each time (states' rates differ).
  final double? outOfStateRate;
  final List<TaxRateChange> rateChanges;

  /// The server's version of these settings (null: the built-in list, nothing saved yet).
  final int? version;
  final String? updatedBy;
  final DateTime? updatedAt;
  const TaxSettings({
    required this.presets,
    this.outOfStateLabel = kOutOfStateLabel,
    this.outOfStateRate,
    this.rateChanges = const [],
    this.version,
    this.updatedBy,
    this.updatedAt,
  });

  static const builtIn = TaxSettings(presets: kBuiltInPresets);

  List<ChargePreset> get discounts => [for (final p in presets) if (!p.fee) p];
  List<ChargePreset> get fees => [for (final p in presets) if (p.fee) p];

  factory TaxSettings.fromJson(Map<String, dynamic> j) {
    final s = j['settings'] is Map ? Map<String, dynamic>.from(j['settings'] as Map) : const <String, dynamic>{};
    final presets = s['presets'] is List
        ? [for (final p in (s['presets'] as List).whereType<Map>()) ChargePreset.fromJson(Map<String, dynamic>.from(p))]
        : kBuiltInPresets;
    final label = (s['outOfStateLabel'] ?? '').toString().trim();
    return TaxSettings(
      presets: presets,
      outOfStateLabel: label.isEmpty ? kOutOfStateLabel : label,
      outOfStateRate: s['outOfStateRate'] is num ? (s['outOfStateRate'] as num).toDouble() : null,
      rateChanges: s['rateChanges'] is List
          ? [for (final c in (s['rateChanges'] as List).whereType<Map>()) TaxRateChange.fromJson(Map<String, dynamic>.from(c))]
          : const [],
      version: j['version'] is num ? (j['version'] as num).toInt() : null,
      updatedBy: j['updatedBy']?.toString(),
      updatedAt: DateTime.tryParse('${j['updatedAt'] ?? ''}'),
    );
  }

  Map<String, dynamic> settingsJson() => {
    'presets': [for (final p in presets) p.toJson()],
    'outOfStateLabel': outOfStateLabel,
    'outOfStateRate': outOfStateRate,
    'rateChanges': [for (final c in rateChanges) c.toJson()],
  };

  TaxSettings copyWith({List<ChargePreset>? presets, String? outOfStateLabel, Object? outOfStateRate = _keep, List<TaxRateChange>? rateChanges}) =>
      TaxSettings(
        presets: presets ?? this.presets,
        outOfStateLabel: outOfStateLabel ?? this.outOfStateLabel,
        outOfStateRate: identical(outOfStateRate, _keep) ? this.outOfStateRate : (outOfStateRate as num?)?.toDouble(),
        rateChanges: rateChanges ?? this.rateChanges,
        version: version,
        updatedBy: updatedBy,
        updatedAt: updatedAt,
      );

  static const _keep = Object();
}

const kOutOfStateLabel = 'Out-of-state sales tax';

const kBuiltInPresets = <ChargePreset>[
  ChargePreset(id: 'd-clopay', fee: false, name: 'Clopay Master Authorized Dealer Discount', mode: ChargeMode.percent),
  ChargePreset(id: 'd-builder', fee: false, name: 'Builder Relationship Discount', mode: ChargeMode.percent),
  ChargePreset(id: 'd-premium-builder', fee: false, name: 'Premium Builder Relationship Discount', mode: ChargeMode.percent),
  ChargePreset(id: 'd-referral', fee: false, name: 'Referral Discount', mode: ChargeMode.percent),
  ChargePreset(id: 'd-service-partner', fee: false, name: 'Service Partner Discount', mode: ChargeMode.amount),
  ChargePreset(id: 'd-same-day', fee: false, name: r'$45 Same Day Service Credit', mode: ChargeMode.amount, value: 45),
  ChargePreset(id: 'd-hbw', fee: false, name: '2-10 HBW Deductible Collected', mode: ChargeMode.amount),
  ChargePreset(id: 'd-multi-door', fee: false, name: 'Multi-Door Discount', mode: ChargeMode.amount),
  ChargePreset(
    id: 'f-card',
    fee: true,
    name: 'Credit Card Convenience Fee - 3% discount for debit, ACH, check, or cash payment',
    mode: ChargeMode.percent,
    value: 3,
  ),
];
