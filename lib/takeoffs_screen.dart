import 'package:flutter/material.dart';

const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);

class TakeoffsScreen extends StatelessWidget {
  const TakeoffsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Takeoffs", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5)),
                ElevatedButton.icon(
                  onPressed: () {}, icon: const Icon(Icons.add, color: Colors.white, size: 18), 
                  label: const Text("New Takeoff", style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)), 
                  style: ElevatedButton.styleFrom(backgroundColor: _brandRed, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _strokeBorder)),
              child: const Center(
                child: Column(
                  children: [
                    Icon(Icons.architecture_outlined, size: 48, color: _slateColor),
                    SizedBox(height: 16),
                    Text("No Takeoffs Yet", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _inkColor)),
                    SizedBox(height: 8),
                    Text("Start building a new material and labor takeoff for a commercial bid.", style: TextStyle(color: _slateColor)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}