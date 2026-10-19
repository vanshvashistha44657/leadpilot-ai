import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/api_models.dart';

class ApiConfig {
  ApiConfig({required String baseUrl, required this.localToken}) : baseUrl = _normalize(baseUrl);

  factory ApiConfig.fromEnvironment() => ApiConfig(
        baseUrl: Platform.environment['LEADPILOT_API_URL'] ?? 'http://127.0.0.1:8000',
        localToken: Platform.environment['LEADPILOT_LOCAL_TOKEN'] ?? 'local-development-token',
      );

  String baseUrl;
  String localToken;

  static String _normalize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'http://127.0.0.1:8000';
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }
}

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null ? message : '$message (HTTP $statusCode)';
}

class ApiService {
  ApiService(this.config);

  final ApiConfig config;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  void updateConnection({required String baseUrl, required String localToken}) {
    config.baseUrl = ApiConfig._normalize(baseUrl);
    config.localToken = localToken.trim();
  }

  void dispose() => _client.close(force: true);

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    List<int>? rawBody,
    String? contentType,
  }) async {
    final uri = Uri.parse('${config.baseUrl}$path').replace(queryParameters: query);
    try {
      final request = await _client.openUrl(method, uri).timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('X-Local-Token', config.localToken);
      if (contentType != null) request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      if (rawBody != null) {
        request.add(rawBody);
      } else if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await response.transform(utf8.decoder).join();
      dynamic decoded;
      if (text.trim().isNotEmpty) {
        try {
          decoded = jsonDecode(text);
        } catch (_) {
          decoded = text;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded is Map ? decoded['detail'] : null;
        throw ApiException(detail?.toString() ?? 'The backend returned an unexpected response.', statusCode: response.statusCode);
      }
      return decoded;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('The backend did not respond in time.');
    } on SocketException catch (error) {
      throw ApiException('Could not connect to ${config.baseUrl}: ${error.message}');
    } on HttpException catch (error) {
      throw ApiException(error.message);
    }
  }

  Future<dynamic> _sendMultipartFile(String method, String path, File file, String filename, {Map<String, String>? query}) async {
    final boundary = 'LeadPilotBoundary${DateTime.now().microsecondsSinceEpoch}';
    final uri = Uri.parse('${config.baseUrl}$path').replace(queryParameters: query);
    try {
      final request = await _client.openUrl(method, uri).timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('X-Local-Token', config.localToken);
      request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
      request.add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$filename"\r\nContent-Type: application/octet-stream\r\n\r\n'));
      await request.addStream(file.openRead());
      request.add(utf8.encode('\r\n--$boundary--\r\n'));
      final response = await request.close().timeout(const Duration(seconds: 30));
      final text = await response.transform(utf8.decoder).join();
      dynamic decoded;
      if (text.trim().isNotEmpty) {
        try {
          decoded = jsonDecode(text);
        } catch (_) {
          decoded = text;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded is Map ? decoded['detail'] : null;
        throw ApiException(detail?.toString() ?? 'The backend returned an unexpected response.', statusCode: response.statusCode);
      }
      return decoded;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('The backend did not respond in time.');
    } on SocketException catch (error) {
      throw ApiException('Could not connect to ${config.baseUrl}: ${error.message}');
    } on HttpException catch (error) {
      throw ApiException(error.message);
    }
  }

  JsonMap _object(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    throw const ApiException('The backend returned an invalid JSON object.');
  }

  List<JsonMap> _objects(dynamic value) {
    if (value is! List) throw const ApiException('The backend returned an invalid JSON list.');
    return value.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
  }

  Future<HealthResponse> checkReady() async => HealthResponse.fromJson(_object(await _send('GET', '/health/ready')));

  Future<HealthResponse> checkLive() async => HealthResponse.fromJson(_object(await _send('GET', '/health/live')));

  Future<DashboardMetrics> getDashboardMetrics() async => DashboardMetrics.fromJson(_object(await _send('GET', '/api/dashboard/metrics')));

  Future<List<Lead>> listLeads({int limit = 1000, int offset = 0, String? search}) async => _objects(await _send('GET', '/api/leads', query: {
        'limit': '$limit',
        'offset': '$offset',
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      })).map(Lead.fromJson).toList();

  Future<int> countLeads({String? search}) async {
    final response = _object(await _send('GET', '/api/leads/count', query: {
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
    }));
    final total = response['total'];
    return total is num ? total.toInt() : int.tryParse('$total') ?? 0;
  }

  Future<Lead> createLead({required String email, String? firstName, String? lastName, String? company, String? title, String? source}) async => Lead.fromJson(_object(await _send('POST', '/api/leads', body: {
        'email': email,
        'first_name': firstName,
        'last_name': lastName,
        'company': company,
        'title': title,
        'source': source,
        'metadata': <String, dynamic>{},
      })));

  Future<ImportResult> importLeads(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw const ApiException('That CSV file does not exist.');
    final filename = file.uri.pathSegments.isEmpty ? 'leads.csv' : file.uri.pathSegments.last;
    final result = await _sendMultipartFile('POST', '/api/leads/import', file, filename);
    return ImportResult.fromJson(_object(result));
  }

  Future<ImportPreview> previewLeadImport(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw const ApiException('That import file does not exist.');
    final filename = file.uri.pathSegments.isEmpty ? 'leads.csv' : file.uri.pathSegments.last;
    return ImportPreview.fromJson(_object(await _sendMultipartFile('POST', '/api/leads/import/preview', file, filename)));
  }

  Future<Job> queueImportLeads(String filePath, {JsonMap? mapping}) async {
    final file = File(filePath);
    if (!await file.exists()) throw const ApiException('That import file does not exist.');
    final filename = file.uri.pathSegments.isEmpty ? 'leads.csv' : file.uri.pathSegments.last;
    final result = await _sendMultipartFile('POST', '/api/leads/import/queue', file, filename, query: mapping == null ? null : {'mapping': jsonEncode(mapping)});
    return Job.fromJson(_object(result));
  }

  Future<PersonalizedDraft> generateDraft({required int leadId, required String offer, required String tone, required String callToAction, bool regenerate = false}) async => PersonalizedDraft.fromJson(_object(await _send('POST', '/api/drafts/generate', body: {'lead_id': leadId, 'offer': offer, 'tone': tone, 'call_to_action': callToAction, 'regenerate': regenerate})));

  Future<List<PersonalizedDraft>> listDrafts({String? status}) async => _objects(await _send('GET', '/api/drafts', query: {if (status != null) 'status': status})).map(PersonalizedDraft.fromJson).toList();

  Future<PersonalizedDraft> updateDraft(String id, {required String subject, required String body}) async => PersonalizedDraft.fromJson(_object(await _send('PATCH', '/api/drafts/$id', body: {'subject': subject, 'body': body})));

  Uri leadsExportUri({String? search}) => Uri.parse('${config.baseUrl}/api/leads/export.csv').replace(queryParameters: {
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      });

  Future<Suppression> addSuppression({required String email, required String reason}) async => Suppression.fromJson(_object(await _send('POST', '/api/suppressions', body: {'email': email, 'reason': reason})));

  Future<LeadResearch> reviewLead(int leadId, {String? websiteUrl, String? verifiedNotes, String source = 'operator_verified'}) async => LeadResearch.fromJson(_object(await _send('POST', '/api/leads/$leadId/research', body: {
        'website_url': websiteUrl,
        'verified_notes': verifiedNotes,
        'source': source,
      })));

  Future<Reply> ingestReply({required String email, required String body, String? subject, String provider = 'manual'}) async => Reply.fromJson(_object(await _send('POST', '/api/replies/ingest', body: {
        'email': email,
        'body': body,
        'subject': subject,
        'provider': provider,
      })));

  Future<List<Reply>> listLeadReplies(int leadId) async => _objects(await _send('GET', '/api/leads/$leadId/replies')).map(Reply.fromJson).toList();

  Future<List<Campaign>> listCampaigns() async => _objects(await _send('GET', '/api/campaigns')).map(Campaign.fromJson).toList();

  Future<Campaign> createCampaign({required String name, bool dryRun = true}) async => Campaign.fromJson(_object(await _send('POST', '/api/campaigns', body: {'name': name, 'dry_run': dryRun})));

  Map<String, dynamic> _outreachBody({required String subject, required String body, List<int>? leadIds, String? provider, bool live = false}) => {
        'subject': subject,
        'body_template': body,
        'lead_ids': leadIds,
        'provider': provider,
        'live': live,
      };

  Future<OutreachPreview> previewOutreach(int campaignId, {required String subject, required String body, List<int>? leadIds, String? provider}) async => OutreachPreview.fromJson(_object(await _send('POST', '/api/campaigns/$campaignId/outreach/dry-run', body: _outreachBody(subject: subject, body: body, leadIds: leadIds, provider: provider))));

  Future<Job> runOutreach(int campaignId, {required String subject, required String body, List<int>? leadIds, String? provider, bool live = false}) async => Job.fromJson(_object(await _send('POST', '/api/campaigns/$campaignId/outreach/run', body: _outreachBody(subject: subject, body: body, leadIds: leadIds, provider: provider, live: live))));

  Future<Job> runOutreachDryRun(int campaignId, {required String subject, required String body, List<int>? leadIds, String? provider}) => runOutreach(campaignId, subject: subject, body: body, leadIds: leadIds, provider: provider, live: false);

  Future<List<Job>> listJobs() async => _objects(await _send('GET', '/api/jobs')).map(Job.fromJson).toList();

  Future<Job> getJob(String jobId) async => Job.fromJson(_object(await _send('GET', '/api/jobs/$jobId')));

  Future<Job> cancelJob(String jobId) async => Job.fromJson(_object(await _send('POST', '/api/jobs/$jobId/cancel')));

  Future<Job> retryJob(String jobId) async => Job.fromJson(_object(await _send('POST', '/api/jobs/$jobId/retry')));

  Future<PricingResult> calculatePricing({required int leads, required double pricePerLead, required double expectedCloseRate, required double revenuePerConversion, required double emailCostPerLead, required double laborCost, required double otherCost, required double platformFeePercent}) async => PricingResult.fromJson(_object(await _send('POST', '/api/pricing/calculate', body: {
        'leads': leads,
        'price_per_lead': pricePerLead,
        'expected_close_rate': expectedCloseRate,
        'revenue_per_conversion': revenuePerConversion,
        'email_cost_per_lead': emailCostPerLead,
        'labor_cost': laborCost,
        'other_cost': otherCost,
        'platform_fee_percent': platformFeePercent,
      })));

  Future<PublicSettings> getSettings() async => PublicSettings.fromJson(_object(await _send('GET', '/api/settings')));

  Future<PublicSettings> updateSettings(JsonMap values) async => PublicSettings.fromJson(_object(await _send('PATCH', '/api/settings', body: values)));

  Future<PublicSettings> stopAutomation() async => PublicSettings.fromJson(_object(await _send('POST', '/api/automation/stop')));

  Future<PublicSettings> resumeAutomation() async => PublicSettings.fromJson(_object(await _send('POST', '/api/automation/resume')));

  Future<List<ProviderStatus>> listProviders() async => _objects(await _send('GET', '/api/providers')).map(ProviderStatus.fromJson).toList();

  Future<AIProviderStatus> getAIStatus() async => AIProviderStatus.fromJson(_object(await _send('GET', '/api/ai/status')));

  Future<AIProviderConfig> getAIConfig() async => AIProviderConfig.fromJson(_object(await _send('GET', '/api/ai/config')));

  Future<AIProviderConfig> updateAIConfig(JsonMap values) async => AIProviderConfig.fromJson(_object(await _send('PATCH', '/api/ai/config', body: values)));

  Future<AIConnectivityResult> checkAIConnectivity() async => AIConnectivityResult.fromJson(_object(await _send('POST', '/api/ai/connectivity')));

  Future<AIUsageSummary> getAIUsage() async => AIUsageSummary.fromJson(_object(await _send('GET', '/api/ai/usage')));

  Future<AIPersonalizationPreview> previewPersonalization({required JsonMap lead, required String offer, required String tone, required String callToAction, String? subjectHint, String? instructions}) async => AIPersonalizationPreview.fromJson(_object(await _send('POST', '/api/ai/personalization/preview', body: {
        'lead': lead,
        'offer': offer,
        'tone': tone,
        'call_to_action': callToAction,
        'subject_hint': subjectHint,
        'instructions': instructions,
      })));

  Future<GmailStatus> getGmailStatus() async => GmailStatus.fromJson(_object(await _send('GET', '/api/gmail/status')));

  Future<GmailHealth> getGmailHealth() async => GmailHealth.fromJson(_object(await _send('GET', '/api/gmail/health')));

  Future<GmailAuthUrl> getGmailAuthUrl([String? state]) async => GmailAuthUrl.fromJson(_object(await _send('GET', '/api/gmail/auth-url', query: state == null || state.trim().isEmpty ? null : {'state': state.trim()})));

  Future<GmailReviewedDraft> createGmailDraft(String localDraftId) async => GmailReviewedDraft.fromJson(_object(await _send('POST', '/api/gmail/drafts/reviewed', body: {'local_draft_id': localDraftId})));

  Future<GmailSyncResult> syncGmailThreads({String? query, String? pageToken, int maxResults = 100, int maxPages = 1}) async => GmailSyncResult.fromJson(_object(await _send('POST', '/api/gmail/sync', body: {
        if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
        if (pageToken != null && pageToken.trim().isNotEmpty) 'page_token': pageToken.trim(),
        'max_results': maxResults,
        'max_pages': maxPages,
      })));

  Future<List<GmailThread>> listGmailThreads({String? query, String? pageToken, int maxResults = 100}) async => _objects(await _send('GET', '/api/gmail/threads', query: {
        if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
        if (pageToken != null && pageToken.trim().isNotEmpty) 'page_token': pageToken.trim(),
        'max_results': '$maxResults',
      })).map(GmailThread.fromJson).toList();

  Future<GmailDisconnect> disconnectGmail() async => GmailDisconnect.fromJson(_object(await _send('POST', '/api/gmail/disconnect')));

  Future<List<WebsitePackage>> listPackages({bool includeInactive = false}) async => _objects(await _send('GET', '/api/packages', query: {'include_inactive': '$includeInactive'})).map(WebsitePackage.fromJson).toList();

  Future<PackageProfitResult> calculatePackageProfit(int packageId, {int months = 12}) async => PackageProfitResult.fromJson(_object(await _send('POST', '/api/packages/$packageId/profit', query: {'months': '$months'})));

  Future<BriefResponse> generateBrief({required String clientName, required String offer, required String targetAudience, required String tone, required String callToAction}) async => BriefResponse.fromJson(_object(await _send('POST', '/api/briefs/generate', body: {
        'client_name': clientName,
        'offer': offer,
        'target_audience': targetAudience,
        'tone': tone,
        'call_to_action': callToAction,
      })));

  Future<List<Client>> listClients({int limit = 100, int offset = 0}) async => _objects(await _send('GET', '/api/clients', query: {'limit': '$limit', 'offset': '$offset'})).map(Client.fromJson).toList();

  Future<Client> createClient({required String companyName, String? contactName, String? email, int? leadId, String? notes}) async => Client.fromJson(_object(await _send('POST', '/api/clients', body: {
        'company_name': companyName,
        'contact_name': contactName,
        'email': email,
        'lead_id': leadId,
        'notes': notes,
        'status': 'prospect',
      })));

  Future<List<Project>> listProjects({int? clientId, int limit = 100}) async => _objects(await _send('GET', '/api/projects', query: {
        'limit': '$limit',
        if (clientId != null) 'client_id': '$clientId',
      })).map(Project.fromJson).toList();

  Future<Project> createProject({required int clientId, required String name, String? previewUrl, String? domain, String? hostingPlan, String? databasePlan}) async => Project.fromJson(_object(await _send('POST', '/api/projects', body: {
        'client_id': clientId,
        'name': name,
        'preview_url': previewUrl,
        'domain': domain,
        'hosting_plan': hostingPlan,
        'database_plan': databasePlan,
      })));

  Future<List<Alert>> listAlerts({bool includeAcknowledged = false}) async => _objects(await _send('GET', '/api/alerts', query: {'include_acknowledged': '$includeAcknowledged'})).map(Alert.fromJson).toList();

  Future<Alert> createAlert({required String severity, required String message}) async => Alert.fromJson(_object(await _send('POST', '/api/alerts', body: {'severity': severity, 'message': message})));

  Future<Alert> acknowledgeAlert(int id) async => Alert.fromJson(_object(await _send('POST', '/api/alerts/$id/acknowledge')));

  Future<List<AuditLogEntry>> listAuditLog({int limit = 100}) async => _objects(await _send('GET', '/api/audit-log', query: {'limit': '$limit'})).map(AuditLogEntry.fromJson).toList();

  Future<JsonMap> backupDatabase() async => _object(await _send('POST', '/api/backup'));
}
