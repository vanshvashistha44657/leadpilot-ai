import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leadpilot_frontend/core/models/api_models.dart';
import 'package:leadpilot_frontend/core/services/api_client.dart';
import 'package:leadpilot_frontend/screens/drafts_screen.dart';
import 'package:leadpilot_frontend/screens/settings_screen.dart';

class _Phase3ApiService extends ApiService {
  _Phase3ApiService({GmailStatus? status, GmailHealth? health})
      : status = status ?? _disconnectedStatus,
        health = health ?? _unhealthyHealth,
        super(ApiConfig(baseUrl: 'http://127.0.0.1:8000', localToken: 'test'));

  static const disconnectedStatus = GmailStatus(
    configured: false,
    tokenAvailable: false,
    senderEmailConfigured: false,
    supportsLiveSend: false,
    reason: 'Gmail OAuth token is not configured',
  );
  static const pendingStatus = GmailStatus(
    configured: false,
    tokenAvailable: true,
    senderEmailConfigured: true,
    supportsLiveSend: false,
    reason: 'Gmail is awaiting health verification',
    senderEmail: 'pending@example.com',
  );
  static const connectedStatus = GmailStatus(
    configured: true,
    tokenAvailable: true,
    senderEmailConfigured: true,
    supportsLiveSend: false,
    reason: 'Gmail Phase 3 is ready',
    senderEmail: 'sender@example.com',
  );
  static const healthy = GmailHealth(
    status: 'healthy',
    detail: 'Gmail profile request succeeded',
    senderIdentity: GmailSenderIdentity(
        emailAddress: 'sender@example.com', messagesTotal: 4, threadsTotal: 2),
  );
  static const unhealthy =
      GmailHealth(status: 'unhealthy', detail: 'Gmail verification failed');
  static const _disconnectedStatus = disconnectedStatus;
  static const _unhealthyHealth = unhealthy;

  GmailStatus status;
  GmailHealth? health;
  GmailSyncResult syncResult = const GmailSyncResult(
    mode: 'full',
    pages: 1,
    threadsSeen: 2,
    threadsStored: 2,
    messagesSeen: 3,
    messagesStored: 3,
    matched: 2,
    unknown: 1,
    ambiguous: 0,
    nextPageToken: 'page-2',
    historyId: '11',
  );
  List<GmailThread> threads = const [
    GmailThread(
        threadId: 'thread-safe-1', snippet: 'Safe snippet', historyId: '10'),
    GmailThread(
        threadId: 'thread-safe-2', snippet: 'Another snippet', historyId: '11'),
  ];
  bool syncThrows = false;
  bool authCalled = false;
  bool verifyCalled = false;
  bool disconnectCalled = false;
  final List<String?> syncPageTokens = [];
  final List<String> createdDraftIds = [];
  bool draftCreateThrowsDuplicate = false;

  final lead = const Lead(
    id: 1,
    email: 'ada@example.com',
    normalizedEmail: 'ada@example.com',
    status: 'new',
    firstName: 'Ada',
    lastName: 'Lovelace',
    company: 'Analytical Engines',
  );

  List<PersonalizedDraft> drafts = [
    _draft('draft-1', status: 'edited'),
  ];
  List<Lead> leads = const [];

  static PersonalizedDraft _draft(String id,
          {String status = 'edited',
          String subject = 'Reviewed subject',
          String body = 'Reviewed body',
          int leadId = 1}) =>
      PersonalizedDraft(
        id: id,
        leadId: leadId,
        status: status,
        provider: 'test-provider',
        model: 'test-model',
        subject: subject,
        body: body,
        generatedSubject: 'Generated subject',
        generatedBody: 'Generated body',
        offer: 'websites',
        tone: 'professional',
        callToAction: 'Reply',
      );

  @override
  Future<PublicSettings> getSettings() async => const PublicSettings(
        dryRun: true,
        liveSendingEnabled: false,
        liveSendReady: false,
        provider: 'mock',
        providerConfigured: true,
        physicalAddressConfigured: false,
        unsubscribeUrlConfigured: false,
        complianceAcknowledged: false,
      );

  @override
  Future<List<ProviderStatus>> listProviders() async => const [
        ProviderStatus(
            name: 'mock',
            configured: true,
            supportsLiveSend: false,
            reason: 'Safe mock')
      ];

  @override
  Future<AIProviderStatus> getAIStatus() async => const AIProviderStatus(
      name: 'test',
      status: 'connected',
      configured: true,
      reason: 'Test provider');

  @override
  Future<AIProviderConfig> getAIConfig() async => const AIProviderConfig(
      provider: 'test',
      timeoutSeconds: 20,
      maxRetries: 1,
      retryBackoffSeconds: 0.1,
      apiKeyConfigured: false);

  @override
  Future<AIUsageSummary> getAIUsage() async =>
      const AIUsageSummary(requests: 0, totalTokens: 0, estimatedCostUsd: 0);

  @override
  Future<HealthResponse> checkReady() async => const HealthResponse(
      status: 'ready', database: 'ok', migrationVersion: 6);

  @override
  Future<GmailStatus> getGmailStatus() async {
    verifyCalled = true;
    return status;
  }

  @override
  Future<GmailHealth> getGmailHealth() async {
    if (health == null) throw const ApiException('health failed');
    return health!;
  }

  @override
  Future<GmailAuthUrl> getGmailAuthUrl([String? state]) async {
    authCalled = true;
    return const GmailAuthUrl(
      authorizationUrl:
          'https://accounts.google.com/o/oauth2/v2/auth?client_id=safe&state=one',
      state: 'one',
    );
  }

  @override
  Future<GmailDisconnect> disconnectGmail() async {
    disconnectCalled = true;
    status = disconnectedStatus;
    health = unhealthy;
    return const GmailDisconnect(status: 'disconnected', providerRevoked: true);
  }

  @override
  Future<GmailReviewedDraft> createGmailDraft(String localDraftId) async {
    if (draftCreateThrowsDuplicate) {
      throw const ApiException('already handled', statusCode: 409);
    }
    createdDraftIds.add(localDraftId);
    return GmailReviewedDraft(
      localDraftId: localDraftId,
      status: 'created',
      providerDraftId: 'safe-draft-1',
      providerThreadId: 'safe-thread-1',
    );
  }

  @override
  Future<GmailSyncResult> syncGmailThreads(
      {String? query,
      String? pageToken,
      int maxResults = 100,
      int maxPages = 1}) async {
    syncPageTokens.add(pageToken);
    if (syncThrows) throw const ApiException('sync failed', statusCode: 502);
    if (pageToken == 'page-2') {
      return const GmailSyncResult(
        mode: 'full',
        pages: 1,
        threadsSeen: 1,
        threadsStored: 1,
        messagesSeen: 1,
        messagesStored: 1,
        matched: 1,
        unknown: 0,
        ambiguous: 0,
      );
    }
    return syncResult;
  }

  @override
  Future<List<GmailThread>> listGmailThreads(
          {String? query, String? pageToken, int maxResults = 100}) async =>
      threads;

  @override
  Future<List<PersonalizedDraft>> listDrafts({String? status}) async => drafts
      .where((draft) => status == null || draft.status == status)
      .toList();

  @override
  Future<List<Lead>> listLeads(
          {int limit = 1000, int offset = 0, String? search}) async =>
      leads.isEmpty ? [lead] : leads;
}

Future<void> _pumpSettings(WidgetTester tester, _Phase3ApiService api,
    {Future<void> Function(Uri uri)? opener}) async {
  tester.view.physicalSize = const Size(1500, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SettingsScreen(
              api: api,
              isDark: false,
              onToggleTheme: () {},
              externalUrlOpener: opener))));
  await tester.pumpAndSettle();
}

Future<void> _pumpDrafts(WidgetTester tester, _Phase3ApiService api) async {
  tester.view.physicalSize = const Size(1500, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester
      .pumpWidget(MaterialApp(home: Scaffold(body: DraftsScreen(api: api))));
  await tester.pumpAndSettle();
}

void main() {
  test('Phase 3 models preserve safe health, draft, and sync fields', () {
    final status = GmailStatus.fromJson({
      'configured': true,
      'token_available': true,
      'sender_email_configured': true,
      'sender_email': 'sender@example.com',
      'supports_live_send': false,
      'health': 'healthy',
      'reason': 'draft-only',
    });
    final health = GmailHealth.fromJson({
      'status': 'healthy',
      'detail': 'verified',
      'sender_identity': {
        'email_address': 'sender@example.com',
        'messages_total': 2,
        'threads_total': 1
      },
    });
    final draft = GmailReviewedDraft.fromJson({
      'local_draft_id': 'local-1',
      'status': 'created',
      'provider_draft_id': 'safe-draft',
      'provider_thread_id': 'safe-thread'
    });
    final sync = GmailSyncResult.fromJson({
      'mode': 'full',
      'pages': 2,
      'threads_seen': 3,
      'threads_stored': 3,
      'messages_seen': 4,
      'messages_stored': 4,
      'matched': 2,
      'unknown': 1,
      'ambiguous': 1,
      'next_page_token': 'next'
    });

    expect(status.senderEmail, 'sender@example.com');
    expect(health.isHealthy, isTrue);
    expect(draft.isCreated, isTrue);
    expect(sync.nextPageToken, 'next');
    expect(sync.isEmpty, isFalse);
  });

  testWidgets(
      'settings renders disconnected, pending, connected, and error states',
      (tester) async {
    final cases = <(_Phase3ApiService, String)>[
      (_Phase3ApiService(), 'Disconnected'),
      (
        _Phase3ApiService(
            status: _Phase3ApiService.pendingStatus,
            health: _Phase3ApiService.healthy),
        'Pending'
      ),
      (
        _Phase3ApiService(
            status: _Phase3ApiService.connectedStatus,
            health: _Phase3ApiService.healthy),
        'Connected'
      ),
      (
        _Phase3ApiService(
            status: _Phase3ApiService.connectedStatus,
            health: _Phase3ApiService.unhealthy),
        'Error'
      ),
    ];

    for (final (api, expected) in cases) {
      await _pumpSettings(tester, api);
      expect(find.text(expected), findsAtLeastNWidgets(1));
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
      'settings uses explicit OAuth connect, verify, and disconnect controls',
      (tester) async {
    final api = _Phase3ApiService();
    Uri? opened;
    await _pumpSettings(tester, api, opener: (uri) async => opened = uri);

    expect(api.authCalled, isFalse);
    expect(api.verifyCalled, isTrue,
        reason: 'initial status load is allowed; no health sync is automatic');
    await tester.ensureVisible(find.text('Connect Gmail'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Connect Gmail'));
    await tester.pumpAndSettle();
    expect(api.authCalled, isTrue);
    expect(opened?.scheme, 'https');
    expect(
        find.textContaining(
            'authorization alone does not confirm a connection'),
        findsOneWidget);

    api.status = _Phase3ApiService.connectedStatus;
    api.health = _Phase3ApiService.healthy;
    await tester.ensureVisible(find.text('Verify Gmail'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify Gmail'));
    await tester.pumpAndSettle();
    expect(find.text('Gmail verified and connected.'), findsOneWidget);

    await tester.ensureVisible(find.text('Disconnect Gmail'));
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect Gmail'));
    await tester.pumpAndSettle();
    expect(api.disconnectCalled, isTrue);
    expect(
        find.text(
            'Gmail disconnected. Local drafts remain in the review queue.'),
        findsOneWidget);
  });

  testWidgets('reviewed local draft creates one Gmail draft and never sends',
      (tester) async {
    final api = _Phase3ApiService(
        status: _Phase3ApiService.connectedStatus,
        health: _Phase3ApiService.healthy);
    await _pumpDrafts(tester, api);

    await tester.tap(find.text('Create Gmail Draft'));
    await tester.pumpAndSettle();

    expect(api.createdDraftIds, ['draft-1']);
    expect(find.text('Gmail draft · not sent'), findsOneWidget);
    expect(find.text('Draft ID: safe-draft-1'), findsOneWidget);
    expect(find.text('Thread ID: safe-thread-1'), findsOneWidget);
  });

  testWidgets(
      'suppressed, missing-email, and invalid drafts keep create disabled',
      (tester) async {
    final api = _Phase3ApiService(
        status: _Phase3ApiService.connectedStatus,
        health: _Phase3ApiService.healthy);
    api.drafts = [
      _Phase3ApiService._draft('eligible'),
      _Phase3ApiService._draft('suppressed', leadId: 2),
      _Phase3ApiService._draft('missing', leadId: 99),
      _Phase3ApiService._draft('invalid', status: 'failed'),
      _Phase3ApiService._draft('empty', subject: ''),
    ];
    api.leads = [
      api.lead,
      const Lead(
          id: 2,
          email: 'blocked@example.com',
          normalizedEmail: 'blocked@example.com',
          status: 'suppressed')
    ];
    await _pumpDrafts(tester, api);

    final createButtons = find.ancestor(
        of: find.text('Create Gmail Draft'),
        matching: find.byType(OutlinedButton));
    expect(createButtons, findsNWidgets(5));
    expect(
        tester
            .widgetList<OutlinedButton>(createButtons)
            .where((button) => button.onPressed != null),
        hasLength(1));
  });

  testWidgets('duplicate Gmail draft response keeps the review queue',
      (tester) async {
    final api = _Phase3ApiService(
        status: _Phase3ApiService.connectedStatus,
        health: _Phase3ApiService.healthy)
      ..draftCreateThrowsDuplicate = true;
    await _pumpDrafts(tester, api);

    await tester.tap(find.text('Create Gmail Draft'));
    await tester.pumpAndSettle();

    expect(find.textContaining('already pending or was already handled'),
        findsOneWidget);
    expect(find.text('Reviewed subject'), findsOneWidget);
    expect(api.createdDraftIds, isEmpty);
  });

  testWidgets(
      'thread sync is manual, paginated, and displays safe counters/snippets',
      (tester) async {
    final api = _Phase3ApiService(
        status: _Phase3ApiService.connectedStatus,
        health: _Phase3ApiService.healthy);
    await _pumpSettings(tester, api);

    expect(api.syncPageTokens, isEmpty);
    expect(find.text('No synchronization run yet.'), findsOneWidget);
    await tester.ensureVisible(find.text('Sync Gmail threads'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sync Gmail threads'));
    await tester.pumpAndSettle();

    expect(api.syncPageTokens, [null]);
    expect(find.text('2 threads'), findsOneWidget);
    expect(find.text('3 messages'), findsOneWidget);
    expect(find.text('Safe snippet'), findsOneWidget);
    expect(find.text('Sync next page'), findsOneWidget);

    await tester.ensureVisible(find.text('Sync next page'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sync next page'));
    await tester.pumpAndSettle();
    expect(api.syncPageTokens, [null, 'page-2']);
  });

  testWidgets('thread sync shows an error without clearing the previous state',
      (tester) async {
    final api = _Phase3ApiService(
        status: _Phase3ApiService.connectedStatus,
        health: _Phase3ApiService.healthy);
    await _pumpSettings(tester, api);
    await tester.ensureVisible(find.text('Sync Gmail threads'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sync Gmail threads'));
    await tester.pumpAndSettle();
    api.syncThrows = true;
    await tester.ensureVisible(find.text('Sync next page'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sync next page'));
    await tester.pumpAndSettle();

    expect(
        find.text(
            'Gmail synchronization failed. The previous sync result was kept.'),
        findsOneWidget);
    expect(find.text('2 threads'), findsOneWidget);
  });
}
