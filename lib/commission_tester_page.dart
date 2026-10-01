import 'package:flutter/material.dart';
import 'dart:math';

class CommissionTesterPage extends StatefulWidget {
  const CommissionTesterPage({Key? key}) : super(key: key);

  @override
  State<CommissionTesterPage> createState() => _CommissionTesterPageState();
}

class TechVisit {
  DateTime date;
  String status;
  double weight;

  TechVisit({
    required this.date,
    this.status = 'Scheduled',
    this.weight = 1.0,
  });
}

class TechInput {
  bool isActive;
  String name;
  double pastAdvances; 
  List<TechVisit> visits;

  TechInput({
    required this.isActive,
    required this.name,
    this.pastAdvances = 0.0,
    required this.visits,
  });
}

class _CommissionTesterPageState extends State<CommissionTesterPage> {
  final TextEditingController _revenueController = TextEditingController(text: '4000');
  final TextEditingController _laborController = TextEditingController(text: '2000');

  bool _isCommercial = false;
  String _jobStatus = 'In Progress';

  final List<String> _payableStatuses = [
    'Final Invoice Sent',
    'Paid & Closed',
    'Paid in Full',
    'Close Job',
    'Google Review Sent'
  ];

  final List<String> _allJobStatuses = [
    'In Progress',
    'Pending Parts',
    'Final Invoice Sent',
    'Paid & Closed',
    'Paid in Full',
    'Close Job',
    'Google Review Sent'
  ];

  final List<String> _visitStatuses = [
    'Scheduled',
    'En Route',
    'In Progress',
    'Completed',
    'Callback',
    'Warranty Work'
  ];

  late List<TechInput> techs;

  @override
  void initState() {
    super.initState();
    DateTime today = DateTime.now();
    techs = [
      TechInput(
          isActive: true,
          name: 'Tech A (Lead)',
          visits: [TechVisit(date: today, weight: 1.5, status: 'Scheduled')]),
      TechInput(
          isActive: true,
          name: 'Tech B (Helper)',
          visits: [TechVisit(date: today, weight: 1.0, status: 'Scheduled')]),
    ];
  }

  @override
  void dispose() {
    _revenueController.dispose();
    _laborController.dispose();
    super.dispose();
  }

  void _recalculate() => setState(() {});

  DateTime _getWeekStart(DateTime date) {
    int daysToSubtract = date.weekday - 1; 
    return DateTime(date.year, date.month, date.day - daysToSubtract);
  }

  Future<void> _selectDate(BuildContext context, TechVisit visit) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: visit.date,
      firstDate: DateTime(2024),
      lastDate: DateTime(2030),
    );
    if (picked != null && picked != visit.date) {
      visit.date = picked;
      _recalculate();
    }
  }

  @override
  Widget build(BuildContext context) {
    double revenue = double.tryParse(_revenueController.text) ?? 0;
    double labor = double.tryParse(_laborController.text) ?? 0;

    bool isJobComplete = _payableStatuses.contains(_jobStatus);
    double commissionRate = _isCommercial ? 0.25 : 0.20;
    
    double baseCommissionPool = labor * commissionRate;
    double companyPoolDeduction = revenue * 0.01;
    double netJobPool = max(0, baseCommissionPool - companyPoolDeduction);

    var activeTechs = techs.where((t) => t.isActive).toList();
    
    Set<DateTime> uniqueWeeks = {};
    DateTime? completionWeek;

    for (var t in activeTechs) {
      for (var v in t.visits) {
        bool isCallback = v.status == 'Callback' || v.status == 'Warranty Work';
        if (v.weight > 0 && !isCallback) {
          DateTime week = _getWeekStart(v.date);
          uniqueWeeks.add(week);
          if (completionWeek == null || week.isAfter(completionWeek)) {
            completionWeek = week;
          }
        }
      }
    }
    bool isMultiWeek = uniqueWeeks.length > 1;

    // Recalculate weights & callback penalties across ALL active techs
    double totalCompletedWeights = 0;
    double totalCallbackPenalties = 0;

    for (var t in activeTechs) {
      for (var v in t.visits) {
        bool isCallback = v.status == 'Callback' || v.status == 'Warranty Work';
        bool isCompleted = v.status == 'Completed';

        if (isCallback) {
          totalCallbackPenalties += 50.0;
        } else if (isCompleted) {
          totalCompletedWeights += v.weight;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dynamic Net Pool Sandbox'),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
      ),
      body: Row(
        children: [
          // LEFT PANEL: CONTROLS
          Expanded(
            flex: 1,
            child: Container(
              color: Colors.grey[100],
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                children: [
                  const Text('1. Office Job Lock', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _jobStatus,
                    decoration: const InputDecoration(labelText: 'Main Job Status'),
                    items: _allJobStatuses.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                    onChanged: (val) {
                      if (val != null) _jobStatus = val;
                      _recalculate();
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _revenueController,
                          decoration: const InputDecoration(labelText: 'Total Revenue (\$)'),
                          keyboardType: TextInputType.number,
                          onChanged: (val) => _recalculate(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _laborController,
                          decoration: const InputDecoration(labelText: 'Labor Cost (\$)'),
                          keyboardType: TextInputType.number,
                          onChanged: (val) => _recalculate(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  SwitchListTile(
                    title: const Text('Commercial Job (25% + Retainage)'),
                    subtitle: const Text('Off = Residential (20%)'),
                    value: _isCommercial,
                    onChanged: (val) {
                      _isCommercial = val;
                      _recalculate();
                    },
                  ),
                  const Divider(height: 40),
                  const Text('2. Tech Visits', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ...techs.map((t) {
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CheckboxListTile(
                              title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              value: t.isActive,
                              onChanged: (val) {
                                t.isActive = val ?? false;
                                _recalculate();
                              },
                            ),
                            if (t.isActive) ...[
                              TextFormField(
                                initialValue: t.pastAdvances.toString(),
                                decoration: const InputDecoration(labelText: 'Manual Old Advances Paid (\$)'),
                                keyboardType: TextInputType.number,
                                onChanged: (val) {
                                  t.pastAdvances = double.tryParse(val) ?? 0.0;
                                  _recalculate();
                                },
                              ),
                              const SizedBox(height: 12),
                              ...t.visits.asMap().entries.map((vEntry) {
                                int vIdx = vEntry.key;
                                TechVisit v = vEntry.value;
                                return Container(
                                  margin: const EdgeInsets.only(top: 8),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.grey[300]!),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: InkWell(
                                              onTap: () => _selectDate(context, v),
                                              child: InputDecorator(
                                                decoration: const InputDecoration(labelText: 'Date', isDense: true),
                                                child: Text("${v.date.month}/${v.date.day}/${v.date.year}"),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: DropdownButtonFormField<String>(
                                              value: v.status,
                                              decoration: const InputDecoration(labelText: 'Visit Status', isDense: true),
                                              items: _visitStatuses.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                                              onChanged: (val) {
                                                if (val != null) v.status = val;
                                                _recalculate();
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: DropdownButtonFormField<double>(
                                              value: v.weight,
                                              decoration: const InputDecoration(labelText: 'Weight', isDense: true),
                                              items: const [
                                                DropdownMenuItem(value: 1.5, child: Text('1.5 (Lead)')),
                                                DropdownMenuItem(value: 1.0, child: Text('1.0 (Helper)')),
                                                DropdownMenuItem(value: 0.5, child: Text('0.5 (Half)')),
                                                DropdownMenuItem(value: 0.0, child: Text('0.0 (Admin)')),
                                              ],
                                              onChanged: (val) {
                                                if (val != null) v.weight = val;
                                                _recalculate();
                                              },
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete, color: Colors.red),
                                            onPressed: () {
                                              t.visits.removeAt(vIdx);
                                              _recalculate();
                                            },
                                          )
                                        ],
                                      )
                                    ],
                                  ),
                                );
                              }).toList(),
                              TextButton.icon(
                                icon: const Icon(Icons.add),
                                label: const Text('Add Work Day'),
                                onPressed: () {
                                  t.visits.add(TechVisit(date: DateTime.now()));
                                  _recalculate();
                                },
                              )
                            ]
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
          ),

          // RIGHT PANEL: DYNAMIC RECEIPT
          Expanded(
            flex: 1,
            child: Container(
              padding: const EdgeInsets.all(24.0),
              color: Colors.white,
              child: ListView(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Net Pool Distribution', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                      if (isJobComplete)
                        Chip(label: const Text('JOB LOCKED', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Colors.red[700])
                      else
                        Chip(label: const Text('JOB OPEN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), backgroundColor: Colors.amber[800]),
                    ],
                  ),
                  const Divider(thickness: 2),

                  _buildLineItem('Base Commission Pool (${(commissionRate * 100).toInt()}%)', '\$${baseCommissionPool.toStringAsFixed(2)}'),
                  _buildLineItem('Company Pool Deduction (1% Rev)', '-\$${companyPoolDeduction.toStringAsFixed(2)}', color: Colors.red),
                  if (totalCallbackPenalties > 0 && !_isCommercial)
                    _buildLineItem('Callback Penalties (Paid by Pool)', '-\$${totalCallbackPenalties.toStringAsFixed(2)}', color: Colors.red),
                  const Divider(),
                  _buildLineItem('TOTAL NET COMMISSION POOL', '\$${netJobPool.toStringAsFixed(2)}', isBold: true),
                  _buildLineItem('Total Completed Weight', '${totalCompletedWeights.toStringAsFixed(1)} pts'),
                  const SizedBox(height: 30),

                  const Text('Live Recalculated Splits', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Divider(),
                  if (activeTechs.isEmpty)
                    const Text('No techs assigned.', style: TextStyle(color: Colors.red))
                  else
                    ...activeTechs.map((t) {
                      double techCompletedWeight = 0;
                      int verifiedAdvanceDays = 0;
                      double callbackFlatFees = 0;

                      for (var v in t.visits) {
                        bool isCallback = v.status == 'Callback' || v.status == 'Warranty Work';
                        bool isCompleted = v.status == 'Completed';

                        if (isCallback) {
                          callbackFlatFees += 50.0;
                        } else if (isCompleted) {
                          techCompletedWeight += v.weight;
                        }

                        if (isMultiWeek && isCompleted && v.weight > 0 && !isCallback) {
                          DateTime weekStart = _getWeekStart(v.date);
                          if (!isJobComplete || weekStart.isBefore(completionWeek!)) {
                            verifiedAdvanceDays++;
                          }
                        }
                      }

                      // Dynamic pool division
                      double shareOfPool = 0;
                      double percentageOfPool = 0;
                      if (totalCompletedWeights > 0 && techCompletedWeight > 0) {
                        percentageOfPool = (techCompletedWeight / totalCompletedWeights) * 100;
                        shareOfPool = netJobPool * (techCompletedWeight / totalCompletedWeights);
                      }

                      double newAdvancesEarned = verifiedAdvanceDays * 200.0;
                      double totalAdvancesToRecoup = t.pastAdvances + (isJobComplete ? newAdvancesEarned : 0);

                      double retainage = 0;
                      double commercialCallbackPenalty = 0;
                      double finalPayout = 0;

                      if (isJobComplete) {
                        retainage = _isCommercial ? (shareOfPool * 0.20) : 0.0;

                        if (_isCommercial && totalCallbackPenalties > 0 && totalCompletedWeights > 0) {
                          double theirShareOfPenalty = totalCallbackPenalties * (techCompletedWeight / totalCompletedWeights);
                          if (retainage >= theirShareOfPenalty) {
                            commercialCallbackPenalty = theirShareOfPenalty;
                            retainage -= theirShareOfPenalty;
                          } else {
                            commercialCallbackPenalty = retainage;
                            retainage = 0;
                          }
                        }

                        double netAfterRetainage = shareOfPool - retainage - commercialCallbackPenalty;
                        finalPayout = max(0, netAfterRetainage - totalAdvancesToRecoup + callbackFlatFees);
                      } else {
                        finalPayout = newAdvancesEarned + callbackFlatFees;
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 20),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: callbackFlatFees > 0 ? Colors.red[50] : Colors.blueGrey[50],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: callbackFlatFees > 0 ? Colors.red[200]! : Colors.transparent),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            const SizedBox(height: 8),

                            if (callbackFlatFees > 0)
                              _buildLineItem('Callback Resolution Fee', '\$${callbackFlatFees.toStringAsFixed(2)}', color: Colors.green[800]),

                            if (techCompletedWeight > 0) ...[
                              _buildLineItem(
                                'Share of Net Pool (${percentageOfPool.toStringAsFixed(1)}%)',
                                '\$${shareOfPool.toStringAsFixed(2)}',
                                isBold: true,
                                color: Colors.blue[800],
                              ),
                              if (!isJobComplete)
                                Text('Recalculates as other techs complete their visits.', style: TextStyle(fontSize: 11, color: Colors.grey[700], fontStyle: FontStyle.italic)),
                            ] else if (callbackFlatFees == 0)
                              const Text('No completed visits yet (0% share of pool).', style: TextStyle(color: Colors.red, fontStyle: FontStyle.italic)),

                            if (_isCommercial && isJobComplete && retainage > 0)
                              _buildLineItem('Commercial Retainage (20%)', '-\$${retainage.toStringAsFixed(2)}', color: Colors.orange),

                            if (totalAdvancesToRecoup > 0 && isJobComplete)
                              _buildLineItem('Advance Repayment', '-\$${totalAdvancesToRecoup.toStringAsFixed(2)}', color: Colors.red),

                            const Divider(),
                            _buildLineItem(
                              isJobComplete ? 'Added to Paycheck' : 'Current Advances/Fees Paid',
                              '\$${finalPayout.toStringAsFixed(2)}',
                              isBold: true,
                              color: Colors.green[800],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLineItem(String label, String value, {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color)),
          Text(value, style: TextStyle(fontWeight: isBold ? FontWeight.bold : FontWeight.normal, color: color ?? Colors.black)),
        ],
      ),
    );
  }
}