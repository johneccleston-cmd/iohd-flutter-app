import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';

class PayrollScreen extends StatefulWidget {
  const PayrollScreen({super.key});

  @override
  State<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends State<PayrollScreen> {
  bool isLoading = false;
  List<dynamic> payrollData = [];
  final NumberFormat currency = NumberFormat.currency(symbol: '\$');
  final DateFormat dateFormat = DateFormat('MMM d, yyyy');

  // Default date range: Last 7 days up to today
  DateTimeRange selectedDateRange = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 7)),
    end: DateTime.now(),
  );

  // Opens the native Flutter calendar range picker
  Future<void> pickDateRange() async {
    final DateTimeRange? newRange = await showDateRangePicker(
      context: context,
      initialDateRange: selectedDateRange,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: Colors.blueAccent,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );

    if (newRange != null) {
      setState(() {
        selectedDateRange = newRange;
      });
    }
  }

  Future<void> generatePayroll() async {
    setState(() {
      isLoading = true;
    });

    final startDateStr = DateFormat('yyyy-MM-dd').format(selectedDateRange.start);
    final endDateStr = DateFormat('yyyy-MM-dd').format(selectedDateRange.end);

    try {
      // Pre-wired with startDate and endDate parameters for when backend logic is ready
      final url = 'https://integrity-backend-cr02.onrender.com/api/payroll/weekly-summary?startDate=$startDateStr&endDate=$endDateStr';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        setState(() {
          payrollData = jsonResponse['data'] ?? [];
          isLoading = false;
        });
      } else {
        setState(() => isLoading = false);
      }
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateRangeText = "${dateFormat.format(selectedDateRange.start)} – ${dateFormat.format(selectedDateRange.end)}";

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('IOHD Hub - Payroll Generator', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: Colors.blueAccent,
        elevation: 2,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- DATE RANGE CONTROL CARD ---
            Card(
              color: Colors.white,
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, color: Colors.blueAccent),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Pay Period Range", style: TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(
                          dateRangeText,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                        ),
                      ],
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.date_range, size: 18),
                      label: const Text("Change Dates"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.blueAccent,
                        side: const BorderSide(color: Colors.blueAccent),
                      ),
                      onPressed: pickDateRange,
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow, color: Colors.white),
                      label: const Text("Run Payroll Report", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      ),
                      onPressed: generatePayroll,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // --- PAYROLL TABLE ---
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : payrollData.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.request_quote, size: 80, color: Colors.grey[400]),
                              const SizedBox(height: 16),
                              Text(
                                "Select a date range above and click 'Run Payroll Report'",
                                style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                              ),
                            ],
                          ),
                        )
                      : Card(
                          color: Colors.white,
                          elevation: 2,
                          child: SizedBox(
                            width: double.infinity,
                            child: SingleChildScrollView(
                              child: DataTable(
                                dataRowMinHeight: 50,
                                dataRowMaxHeight: double.infinity,
                                headingRowColor: WidgetStateProperty.all(Colors.grey[200]),
                                columns: const [
                                  DataColumn(label: Text('Technician', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                                  DataColumn(label: Text('Jobs Worked', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                                  DataColumn(label: Text('Penalized (Lost)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                                  DataColumn(label: Text('Take Home Pay', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87))),
                                ],
                                rows: payrollData.map((tech) {
                                  double takeHome = double.tryParse(tech['take_home_pay'].toString()) ?? 0.0;
                                  double penalized = double.tryParse(tech['penalized_amount'].toString()) ?? 0.0;

                                  return DataRow(cells: [
                                    DataCell(Text(tech['tech_name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black87))),
                                    DataCell(Text(tech['jobs_worked'].toString(), style: const TextStyle(color: Colors.black87))),
                                    DataCell(Text(currency.format(penalized), style: const TextStyle(color: Colors.redAccent))),
                                    DataCell(Text(currency.format(takeHome), style: TextStyle(color: Colors.green[800], fontWeight: FontWeight.bold, fontSize: 16))),
                                  ]);
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}