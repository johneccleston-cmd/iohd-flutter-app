import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';

Future<void> finalizePayroll(List<Map<String, dynamic>> payouts, BuildContext context) async {
  // Replace with your actual Render backend URL
  final String apiUrl = 'https://your-render-app.onrender.com/api/commissions/lock';

  try {
    final response = await http.post(
      Uri.parse(apiUrl),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'payouts': payouts,
      }),
    );

    if (response.statusCode == 200) {
      final responseData = jsonDecode(response.body);
      
      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(responseData['message'] ?? 'Payroll locked successfully!'),
          backgroundColor: Colors.green,
        ),
      );
      
      // TODO: Refresh your dashboard state or clear the screen here
      
    } else {
      final errorData = jsonDecode(response.body);
      throw Exception(errorData['error'] ?? 'Failed to lock payroll');
    }
  } catch (e) {
    // Show error message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Error: ${e.toString()}'),
        backgroundColor: Colors.red,
      ),
    );
  }
}