// Follow-up memory: the lookups behind an answer (the server's `lookups`: tool and arguments) are kept with that answer,
// saved with the chat, and sent back with it in later questions, so "show the full list" can re-run the same lookup.
// Production logs (Nov 2026) showed follow-ups starting over, and once the person pasted "How I got this" back in by hand.
// Run:  flutter test test/assistant_followup_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/widgets/assistant_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  AssistantChat.animateAnswers = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AssistantChat.instance.clear();
    AssistantChat.instance.pagePath = '';
    AssistantChat.instance.pageContext = '';
  });

  const sql = "SELECT job_id FROM jobs WHERE sales_agents ILIKE '%Heather%'";

  test('the lookups behind an answer go back with it in the next question, and are saved with the chat', () async {
    final sent = <List<dynamic>>[];
    final client = MockClient((req) async {
      final body = json.decode(req.body) as Map<String, dynamic>;
      sent.add(body['messages'] as List);
      final first = sent.length == 1;
      return http.Response(
        jsonEncode({
          'success': true,
          'answer': first ? '70 jobs.' : 'Here is the full list.',
          'toolsUsed': ['run_sql'],
          'calls': [
            {'tool': 'run_sql', 'input': jsonEncode({'sql': sql}), 'ok': true},
          ],
          if (first)
            'lookups': [
              {'tool': 'run_sql', 'input': jsonEncode({'sql': sql, 'purpose': 'agent jobs'})},
              {'tool': '', 'input': '{}'}, // malformed: dropped
              'nonsense', // not a lookup: dropped
            ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    await http.runWithClient(() async {
      final chat = AssistantChat.instance;
      await chat.send('Jobs Heather was agent on');
      final answer = chat.messages.last;
      expect(answer.text, '70 jobs.');
      expect(answer.replay, [
        {'tool': 'run_sql', 'input': jsonEncode({'sql': sql, 'purpose': 'agent jobs'})},
      ]);

      await chat.send('Show the full 70-job list');
      final history = sent.last;
      expect(history.length, 3);
      expect(history[0], {'role': 'user', 'content': 'Jobs Heather was agent on'});
      expect(history[1]['role'], 'assistant');
      expect(history[1]['lookups'], [
        {'tool': 'run_sql', 'input': jsonEncode({'sql': sql, 'purpose': 'agent jobs'})},
      ]);
      expect((history[2] as Map).containsKey('lookups'), isFalse, reason: 'questions carry no lookups');

      // saved with the chat, and read back
      final prefs = await SharedPreferences.getInstance();
      final saved = json.decode(prefs.getString('iohd_assistant_chat')!) as Map<String, dynamic>;
      final msgs = ((saved['tabs'] as List).first as Map)['messages'] as List;
      expect((msgs[1] as Map)['replay'], [
        {'tool': 'run_sql', 'input': jsonEncode({'sql': sql, 'purpose': 'agent jobs'})},
      ]);
      expect((msgs[3] as Map).containsKey('replay'), isFalse, reason: 'an answer without lookups saves none');
    }, () => client);
  });
}
