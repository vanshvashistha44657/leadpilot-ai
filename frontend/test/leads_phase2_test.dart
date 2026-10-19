import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leadpilot_frontend/core/models/api_models.dart';
import 'package:leadpilot_frontend/core/services/api_client.dart';
import 'package:leadpilot_frontend/screens/leads_screen.dart';

class _FakeApiService extends ApiService {
  _FakeApiService() : super(ApiConfig(baseUrl: 'http://127.0.0.1:8000', localToken: 'test'));

  final lead = const Lead(id: 1, email: 'ada@example.com', normalizedEmail: 'ada@example.com', status: 'new', firstName: 'Ada', company: 'Acme', source: 'csv');
  bool updatedDraft = false;
  bool generatedDraft = false;

  @override
  Future<List<Lead>> listLeads({int limit = 1000, int offset = 0, String? search}) async => search == null || search.isEmpty || search == 'acme' ? [lead] : const [];

  @override
  Future<int> countLeads({String? search}) async => search == null || search.isEmpty || search == 'acme' ? 1 : 0;

  @override
  Future<ImportPreview> previewLeadImport(String filePath) async => const ImportPreview(filename: 'leads.csv', fileType: 'csv', columns: ['Email', 'Company'], suggestedMapping: {'Email': 'email', 'Company': 'company'}, sampleRows: [{'Email': 'ada@example.com'}], rowCount: 2, limitExceeded: false, errors: ['row 3: invalid email']);

  @override
  Future<Job> queueImportLeads(String filePath, {JsonMap? mapping}) async => const Job(id: 'job-1', jobType: 'lead_import', status: 'queued', progress: 0, attempts: 0, maxAttempts: 3, cancelRequested: false, payload: {});

  @override
  Future<PersonalizedDraft> generateDraft({required int leadId, required String offer, required String tone, required String callToAction, bool regenerate = false}) async {
    generatedDraft = true;
    return const PersonalizedDraft(id: 'draft-1', leadId: 1, status: 'generated', provider: 'test', model: 'test', subject: 'AI subject', body: 'AI body', generatedSubject: 'AI subject', generatedBody: 'AI body', offer: 'websites', tone: 'professional', callToAction: 'Reply');
  }

  @override
  Future<PersonalizedDraft> updateDraft(String id, {required String subject, required String body}) async {
    updatedDraft = true;
    return PersonalizedDraft(id: id, leadId: 1, status: 'edited', provider: 'test', model: 'test', subject: subject, body: body, generatedSubject: 'AI subject', generatedBody: 'AI body', offer: 'websites', tone: 'professional', callToAction: 'Reply');
  }
}

void main() {
  testWidgets('import preview shows mapping and errors before queueing', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _FakeApiService();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LeadsScreen(api: api))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'leads.csv');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Import'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Preview leads.csv'), findsOneWidget);
    expect(find.text('row 3: invalid email'), findsOneWidget);
    expect(find.text('Queue import'), findsOneWidget);
  });

  testWidgets('lead search filtering and editable draft review work', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _FakeApiService();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LeadsScreen(api: api))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'acme');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('ada@example.com'), findsOneWidget);

    final draftButton = find.byIcon(Icons.auto_awesome_outlined);
    await tester.ensureVisible(draftButton);
    await tester.tap(draftButton);
    await tester.pumpAndSettle();
    final offerField = find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Offer / service brief *');
    await tester.enterText(offerField, 'websites');
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Generate draft'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.generatedDraft, isTrue);
    expect(find.text('Review personalized draft'), findsOneWidget);
    final editorFields = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(editorFields.first, 'Edited subject');
    await tester.tap(find.text('Save edited draft'));
    await tester.pumpAndSettle();
    expect(api.updatedDraft, isTrue);
  });
}
