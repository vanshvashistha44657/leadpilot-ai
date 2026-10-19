import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leadpilot_frontend/core/models/api_models.dart';
import 'package:leadpilot_frontend/core/services/api_client.dart';
import 'package:leadpilot_frontend/screens/drafts_screen.dart';

class _DraftApiService extends ApiService {
  _DraftApiService()
      : super(ApiConfig(baseUrl: 'http://127.0.0.1:8000', localToken: 'test'));

  final lead = const Lead(
    id: 1,
    email: 'ada@example.com',
    normalizedEmail: 'ada@example.com',
    status: 'new',
    firstName: 'Ada',
    lastName: 'Lovelace',
    company: 'Analytical Engines',
    title: 'Owner',
  );

  late final List<PersonalizedDraft> drafts = [
    _draft(id: 'draft-generated', status: 'generated'),
    _draft(
        id: 'draft-edited',
        status: 'edited',
        subject: 'Edited subject',
        body: 'Edited body'),
    _draft(
        id: 'draft-failed',
        status: 'failed',
        subject: '',
        body: '',
        error: 'provider unavailable'),
  ];

  bool updateCalled = false;
  bool generateCalled = false;
  bool? regenerateValue;
  int? generatedLeadId;
  String? generatedOffer;
  String? generatedTone;
  String? generatedCallToAction;
  String? updatedSubject;
  String? updatedBody;

  PersonalizedDraft _draft(
          {required String id,
          required String status,
          String subject = 'Generated subject',
          String body = 'Generated body',
          String? error}) =>
      PersonalizedDraft(
        id: id,
        leadId: 1,
        status: status,
        provider: 'test-provider',
        model: 'test-model',
        subject: subject,
        body: body,
        generatedSubject: 'Generated subject',
        generatedBody: 'Generated body',
        offer: 'websites for local businesses',
        tone: 'professional',
        callToAction: 'Reply if useful.',
        error: error,
      );

  @override
  Future<List<PersonalizedDraft>> listDrafts({String? status}) async => drafts
      .where((draft) => status == null || draft.status == status)
      .toList();

  @override
  Future<List<Lead>> listLeads(
          {int limit = 1000, int offset = 0, String? search}) async =>
      [lead];

  @override
  Future<PersonalizedDraft> updateDraft(String id,
      {required String subject, required String body}) async {
    updateCalled = true;
    updatedSubject = subject;
    updatedBody = body;
    final index = drafts.indexWhere((draft) => draft.id == id);
    final previous = drafts[index];
    final updated = PersonalizedDraft(
      id: previous.id,
      leadId: previous.leadId,
      status: 'edited',
      provider: previous.provider,
      model: previous.model,
      subject: subject,
      body: body,
      generatedSubject: previous.generatedSubject,
      generatedBody: previous.generatedBody,
      offer: previous.offer,
      tone: previous.tone,
      callToAction: previous.callToAction,
      error: previous.error,
    );
    drafts[index] = updated;
    return updated;
  }

  @override
  Future<PersonalizedDraft> generateDraft(
      {required int leadId,
      required String offer,
      required String tone,
      required String callToAction,
      bool regenerate = false}) async {
    generateCalled = true;
    regenerateValue = regenerate;
    generatedLeadId = leadId;
    generatedOffer = offer;
    generatedTone = tone;
    generatedCallToAction = callToAction;
    final index = drafts.indexWhere((draft) => draft.leadId == leadId);
    final previous = drafts[index];
    final regenerated = PersonalizedDraft(
      id: previous.id,
      leadId: previous.leadId,
      status: 'generated',
      provider: previous.provider,
      model: previous.model,
      subject: 'Regenerated subject',
      body: 'Regenerated body',
      generatedSubject: 'Regenerated subject',
      generatedBody: 'Regenerated body',
      offer: offer,
      tone: tone,
      callToAction: callToAction,
    );
    drafts[index] = regenerated;
    return regenerated;
  }
}

Future<void> _pumpDrafts(WidgetTester tester, _DraftApiService api) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester
      .pumpWidget(MaterialApp(home: Scaffold(body: DraftsScreen(api: api))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'draft queue loads identity, previews content, and shows statuses',
      (tester) async {
    final api = _DraftApiService();
    await _pumpDrafts(tester, api);

    expect(find.text('Ada Lovelace'), findsNWidgets(3));
    expect(find.text('ada@example.com · Analytical Engines · Owner'),
        findsNWidgets(3));
    expect(find.text('generated'), findsOneWidget);
    expect(find.text('edited'), findsOneWidget);
    expect(find.text('failed'), findsOneWidget);
    expect(find.text('Generated subject'), findsOneWidget);
    expect(find.text('Generated body'), findsOneWidget);
    expect(
        find.text('Generation failed: provider unavailable'), findsOneWidget);
    expect(find.text('No send actions'), findsNothing);
  });

  testWidgets('draft queue edits and saves the selected draft', (tester) async {
    final api = _DraftApiService();
    await _pumpDrafts(tester, api);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Edit draft').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit personalized draft'), findsOneWidget);

    final subject = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == 'Subject');
    final body = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == 'Body');
    await tester.enterText(subject, 'Reviewed subject');
    await tester.enterText(body, 'Reviewed body');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save draft'));
    await tester.pumpAndSettle();

    expect(api.updateCalled, isTrue);
    expect(api.updatedSubject, 'Reviewed subject');
    expect(api.updatedBody, 'Reviewed body');
    expect(find.text('Reviewed subject'), findsOneWidget);
  });

  testWidgets('regenerate uses the stored prompt settings and explicit flag',
      (tester) async {
    final api = _DraftApiService();
    await _pumpDrafts(tester, api);

    await tester.tap(find.widgetWithText(TextButton, 'Regenerate').first);
    await tester.pumpAndSettle();

    expect(api.generateCalled, isTrue);
    expect(api.regenerateValue, isTrue);
    expect(api.generatedLeadId, 1);
    expect(api.generatedOffer, 'websites for local businesses');
    expect(api.generatedTone, 'professional');
    expect(api.generatedCallToAction, 'Reply if useful.');
    expect(find.text('Regenerated subject'), findsOneWidget);
  });
}
