import 'package:flutter/material.dart';

class JobDetailsDialog extends StatelessWidget {
  final Map<String, dynamic> job;

  const JobDetailsDialog({super.key, required this.job});

  // Exact color palette from Android XML
  static const Color bgColor = Color(0xFFF8F9FB);
  static const Color primaryTextColor = Color(0xFF1A1C1E);
  static const Color secondaryTextColor = Color(0xFF4B5563);
  static const Color sectionLabelColor = Color(0xFF9CA3AF);
  static const Color locationRedColor = Color(0xFFCC0007);
  static const Color primaryRedButton = Color(0xFFCC0007);
  static const Color paymentGreenButton = Color(0xFF1A7A4A);
  static const Color strokeBorderColor = Color(0xFFE5E7EB);
  static const Color dividerColor = Color(0xFFE5E7EB);

  // Warning Notes Card Colors
  static const Color notesBgColor = Color(0xFFFFFBF0);
  static const Color notesStrokeColor = Color(0xFFF5DFA0);
  static const Color notesHeaderColor = Color(0xFFB07D10);
  static const Color notesTextColor = Color(0xFF7A5A10);

  Color _getStatusColor(String status) {
    switch (status.trim().toLowerCase()) {
      case 'need deposit':
        return const Color(0xFFA80000);
      case 'need to order':
        return const Color(0xFF00B3FF);
      case 'manage project':
      case 'verify delivery':
        return const Color(0xFF0051FF);
      case 'need to schedule':
        return const Color(0xFF08EB00);
      case 'site check':
      case 'scheduled':
      case 'warranty work':
      case 'callback':
        return const Color(0xFF009E18);
      case 'appointment':
        return const Color(0xFF00B51B);
      case 'delayed':
      case 'need to warranty':
      case 'partially complete':
        return const Color(0xFFFFAE00);
      case 'need to sell':
      case 'google review sent':
        return const Color(0xFF000AC4);
      case 'cancelled':
        return const Color(0xFF592D00);
      case 'complete':
        return const Color(0xFF9C9C9C);
      case 'final invoice sent':
        return const Color(0xFFDB0000);
      case 'write-off':
        return const Color(0xFFD92100);
      case 'close job':
      case 'paid & closed':
        return const Color(0xFF000000);
      case 'part ordered':
        return const Color(0xFF7F83EB);
      case 'estimate requested':
      case 'estimate follow up':
      case 'estimate accepted':
        return const Color(0xFFEB36FF);
      case 'estimate provided':
        return const Color(0xFF5F0069);
      case 'estimate won':
        return const Color(0xFF3C0045);
      case 'lost':
        return const Color(0xFF59320C);
      case '14 day notice':
      case '30 day notice':
      case '60 day notice':
      case '90 day notice':
      case 'check on payment':
        return const Color(0xFFFF0000);
      default:
        return const Color(0xFF9C9C9C);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String jobId = (job['job_id'] ?? '---').toString();
    final String status = (job['status'] ?? 'PENDING').toString();
    final String customerName = (job['customer_name'] ?? 'Customer Name').toString();
    final String contactName = (job['contact_name'] ?? 'Contact Name').toString();
    final String location = (job['location'] ?? 'No Address Provided').toString();
    final String techs = (job['techs_assigned'] ?? 'Unassigned').toString();
    final String poNumber = (job['po_number'] ?? '').toString();
    final String description = (job['description'] ?? 'No description provided.').toString();
    final String techNotes = (job['notes'] ?? '').toString();
    final String rawItems = (job['raw_items'] ?? '').toString();

    return Dialog(
      backgroundColor: bgColor,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 850),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Scaffold(
            backgroundColor: bgColor,
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- HEADER: JOB NUMBER & STATUS BADGE ---
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Job #$jobId",
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: primaryTextColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _getStatusColor(status),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          status.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // --- CARD 1: CUSTOMER & CONTACT ---
                  _buildCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionLabel("CUSTOMER"),
                        const SizedBox(height: 4),
                        Text(
                          customerName,
                          style: const TextStyle(fontSize: 18, color: secondaryTextColor),
                        ),
                        _buildDivider(),
                        _buildSectionLabel("CONTACT"),
                        const SizedBox(height: 4),
                        Text(
                          contactName,
                          style: const TextStyle(fontSize: 15, color: secondaryTextColor),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // --- CARD 2: LOCATION, TECHS, PO, DESCRIPTION ---
                  _buildCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionLabel("LOCATION"),
                        const SizedBox(height: 4),
                        Text(
                          location,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: locationRedColor,
                          ),
                        ),
                        _buildDivider(),
                        _buildSectionLabel("ASSIGNED TECHS"),
                        const SizedBox(height: 4),
                        Text(
                          techs,
                          style: const TextStyle(fontSize: 15, color: secondaryTextColor),
                        ),
                        if (poNumber.trim().isNotEmpty) ...[
                          _buildDivider(),
                          Row(
                            children: [
                              _buildSectionLabel("PO#:"),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  poNumber,
                                  style: const TextStyle(fontSize: 15, color: secondaryTextColor),
                                ),
                              ),
                            ],
                          ),
                        ],
                        _buildDivider(),
                        _buildSectionLabel("JOB DESCRIPTION"),
                        const SizedBox(height: 4),
                        Text(
                          description,
                          style: const TextStyle(
                            fontSize: 14,
                            color: secondaryTextColor,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // --- CARD 3: NOTES FOR TECHS (CONDITIONAL) ---
                  if (techNotes.trim().isNotEmpty) ...[
                    Card(
                      elevation: 0,
                      color: notesBgColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: notesStrokeColor, width: 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(18.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "NOTES FOR TECHS",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: notesHeaderColor,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              techNotes,
                              style: const TextStyle(
                                fontSize: 14,
                                color: notesTextColor,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // --- CARD 4: LINE ITEMS (CONDITIONAL) ---
                  if (rawItems.trim().isNotEmpty && rawItems != '[]') ...[
                    _buildCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSectionLabel("LINE ITEMS"),
                          const SizedBox(height: 4),
                          Text(
                            rawItems,
                            style: const TextStyle(
                              fontSize: 14,
                              color: secondaryTextColor,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  const SizedBox(height: 12),

                  // --- ACTION BUTTONS ---
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryRedButton,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text(
                        "START SITE CHECK",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      onPressed: () {},
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.white,
                        elevation: 0,
                        side: const BorderSide(color: strokeBorderColor, width: 1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text(
                        "OPEN SERVICE FUSION",
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: paymentGreenButton,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text(
                        "COLLECT PAYMENT",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: strokeBorderColor, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: child,
      ),
    );
  }

  Widget _buildSectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: sectionLabelColor,
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _buildDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14.0),
      child: Divider(height: 1, color: dividerColor),
    );
  }
}