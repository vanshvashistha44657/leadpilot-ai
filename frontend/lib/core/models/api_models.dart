typedef JsonMap = Map<String, dynamic>;

int _int(Object? value) => value is num ? value.toInt() : int.tryParse('$value') ?? 0;
double _double(Object? value) => value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
bool _bool(Object? value) => value == true || value == 1 || value == 'true';
String _string(Object? value) => value?.toString() ?? '';
DateTime? _date(Object? value) => value == null ? null : DateTime.tryParse(value.toString());
JsonMap _map(Object? value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

class Lead {
  const Lead({
    required this.id,
    required this.email,
    required this.normalizedEmail,
    required this.status,
    this.firstName,
    this.lastName,
    this.company,
    this.title,
    this.source,
    this.metadata = const {},
    this.createdAt,
    this.updatedAt,
    this.opportunityScore = 0,
    this.researchStatus = 'unresearched',
    this.websiteUrl,
    this.researchNotes,
  });

  final int id;
  final String email;
  final String normalizedEmail;
  final String status;
  final String? firstName;
  final String? lastName;
  final String? company;
  final String? title;
  final String? source;
  final JsonMap metadata;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get displayName => [firstName, lastName].where((part) => part != null && part.trim().isNotEmpty).join(' ');

  factory Lead.fromJson(JsonMap json) => Lead(
        id: _int(json['id']),
        email: _string(json['email']),
        normalizedEmail: _string(json['normalized_email']),
        status: _string(json['status']),
        firstName: json['first_name']?.toString(),
        lastName: json['last_name']?.toString(),
        company: json['company']?.toString(),
        title: json['title']?.toString(),
        source: json['source']?.toString(),
        metadata: _map(json['metadata']),
        createdAt: _date(json['created_at']),
        updatedAt: _date(json['updated_at']),
        opportunityScore: _int(json['opportunity_score']),
        researchStatus: _string(json['research_status']),
        websiteUrl: json['website_url']?.toString(),
        researchNotes: json['research_notes']?.toString(),
      );

  final int opportunityScore;
  final String researchStatus;
  final String? websiteUrl;
  final String? researchNotes;
}

class ImportResult {
  const ImportResult({required this.imported, required this.duplicates, required this.suppressed, required this.invalid, required this.processed, this.skipped = 0, this.batchId, this.errors = const []});

  final int imported;
  final int duplicates;
  final int suppressed;
  final int invalid;
  final int processed;
  final int skipped;
  final String? batchId;
  final List<String> errors;

  factory ImportResult.fromJson(JsonMap json) => ImportResult(
        imported: _int(json['imported']),
        duplicates: _int(json['duplicates']),
        suppressed: _int(json['suppressed']),
        invalid: _int(json['invalid']),
        processed: _int(json['processed']),
        skipped: _int(json['skipped']),
        batchId: json['batch_id']?.toString(),
        errors: (json['errors'] as List? ?? const []).map((value) => value.toString()).toList(),
      );
}

class ImportPreview {
  const ImportPreview({required this.filename, required this.fileType, required this.columns, required this.suggestedMapping, required this.sampleRows, required this.rowCount, required this.limitExceeded, this.errors = const []});

  final String filename;
  final String fileType;
  final List<String> columns;
  final JsonMap suggestedMapping;
  final List<JsonMap> sampleRows;
  final int rowCount;
  final bool limitExceeded;
  final List<String> errors;

  factory ImportPreview.fromJson(JsonMap json) => ImportPreview(filename: _string(json['filename']), fileType: _string(json['file_type']), columns: (json['columns'] as List? ?? const []).map((item) => item.toString()).toList(), suggestedMapping: _map(json['suggested_mapping']), sampleRows: (json['sample_rows'] as List? ?? const []).map((item) => _map(item)).toList(), rowCount: _int(json['row_count']), limitExceeded: _bool(json['limit_exceeded']), errors: (json['errors'] as List? ?? const []).map((item) => item.toString()).toList());
}

class PersonalizedDraft {
  const PersonalizedDraft({required this.id, required this.leadId, required this.status, required this.provider, required this.model, required this.subject, required this.body, required this.generatedSubject, required this.generatedBody, required this.offer, required this.tone, required this.callToAction, this.error, this.updatedAt});

  final String id;
  final int leadId;
  final String status;
  final String provider;
  final String model;
  final String subject;
  final String body;
  final String generatedSubject;
  final String generatedBody;
  final String offer;
  final String tone;
  final String callToAction;
  final String? error;
  final DateTime? updatedAt;

  factory PersonalizedDraft.fromJson(JsonMap json) => PersonalizedDraft(id: _string(json['id']), leadId: _int(json['lead_id']), status: _string(json['status']), provider: _string(json['provider']), model: _string(json['model']), subject: _string(json['subject']), body: _string(json['body']), generatedSubject: _string(json['generated_subject']), generatedBody: _string(json['generated_body']), offer: _string(json['offer']), tone: _string(json['tone']), callToAction: _string(json['call_to_action']), error: json['error']?.toString(), updatedAt: _date(json['updated_at']));
}

class Suppression {
  const Suppression({required this.id, required this.normalizedEmail, required this.reason, this.createdAt});

  final int id;
  final String normalizedEmail;
  final String reason;
  final DateTime? createdAt;

  factory Suppression.fromJson(JsonMap json) => Suppression(
        id: _int(json['id']),
        normalizedEmail: _string(json['normalized_email']),
        reason: _string(json['reason']),
        createdAt: _date(json['created_at']),
      );
}

class LeadResearch {
  const LeadResearch({required this.leadId, required this.opportunityScore, required this.researchStatus, required this.source, this.websiteUrl, this.researchNotes});

  final int leadId;
  final int opportunityScore;
  final String researchStatus;
  final String source;
  final String? websiteUrl;
  final String? researchNotes;

  factory LeadResearch.fromJson(JsonMap json) => LeadResearch(leadId: _int(json['lead_id']), opportunityScore: _int(json['opportunity_score']), researchStatus: _string(json['research_status']), source: _string(json['source']), websiteUrl: json['website_url']?.toString(), researchNotes: json['research_notes']?.toString());
}

class Reply {
  const Reply({required this.id, required this.leadId, required this.provider, required this.body, required this.classification, this.subject, this.createdAt});

  final int id;
  final int leadId;
  final String provider;
  final String? subject;
  final String body;
  final String classification;
  final DateTime? createdAt;

  factory Reply.fromJson(JsonMap json) => Reply(id: _int(json['id']), leadId: _int(json['lead_id']), provider: _string(json['provider']), subject: json['subject']?.toString(), body: _string(json['body']), classification: _string(json['classification']), createdAt: _date(json['created_at']));
}

class Campaign {
  const Campaign({required this.id, required this.name, required this.status, required this.dryRun, this.createdAt, this.updatedAt});

  final int id;
  final String name;
  final String status;
  final bool dryRun;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Campaign.fromJson(JsonMap json) => Campaign(
        id: _int(json['id']),
        name: _string(json['name']),
        status: _string(json['status']),
        dryRun: _bool(json['dry_run']),
        createdAt: _date(json['created_at']),
        updatedAt: _date(json['updated_at']),
      );
}

class OutreachPreviewItem {
  const OutreachPreviewItem({required this.leadId, required this.email, required this.subject, required this.body, required this.suppressed});

  final int leadId;
  final String email;
  final String subject;
  final String body;
  final bool suppressed;

  factory OutreachPreviewItem.fromJson(JsonMap json) => OutreachPreviewItem(
        leadId: _int(json['lead_id']),
        email: _string(json['email']),
        subject: _string(json['subject']),
        body: _string(json['body']),
        suppressed: _bool(json['suppressed']),
      );
}

class OutreachPreview {
  const OutreachPreview({required this.campaignId, required this.items});

  final int campaignId;
  final List<OutreachPreviewItem> items;

  factory OutreachPreview.fromJson(JsonMap json) => OutreachPreview(
        campaignId: _int(json['campaign_id']),
        items: (json['items'] as List? ?? const []).map((item) => OutreachPreviewItem.fromJson(_map(item))).toList(),
      );
}

class Job {
  const Job({required this.id, required this.jobType, required this.status, required this.progress, required this.attempts, required this.maxAttempts, required this.cancelRequested, required this.payload, this.result, this.error, this.createdAt, this.startedAt, this.finishedAt, this.updatedAt});

  final String id;
  final String jobType;
  final String status;
  final int progress;
  final int attempts;
  final int maxAttempts;
  final bool cancelRequested;
  final JsonMap payload;
  final JsonMap? result;
  final String? error;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final DateTime? updatedAt;

  bool get canCancel => status == 'queued' || status == 'running';

  factory Job.fromJson(JsonMap json) => Job(
        id: _string(json['id']),
        jobType: _string(json['job_type']),
        status: _string(json['status']),
        progress: _int(json['progress']),
        attempts: _int(json['attempts']),
        maxAttempts: _int(json['max_attempts']),
        cancelRequested: _bool(json['cancel_requested']),
        payload: _map(json['payload']),
        result: json['result'] == null ? null : _map(json['result']),
        error: json['error']?.toString(),
        createdAt: _date(json['created_at']),
        startedAt: _date(json['started_at']),
        finishedAt: _date(json['finished_at']),
        updatedAt: _date(json['updated_at']),
      );
}

class PricingResult {
  const PricingResult({required this.billableRevenue, required this.expectedConversions, required this.expectedDownstreamRevenue, required this.deliveryCost, required this.platformFee, required this.totalCost, required this.netProfit, required this.marginPercent});

  final double billableRevenue;
  final double expectedConversions;
  final double expectedDownstreamRevenue;
  final double deliveryCost;
  final double platformFee;
  final double totalCost;
  final double netProfit;
  final double marginPercent;

  factory PricingResult.fromJson(JsonMap json) => PricingResult(
        billableRevenue: _double(json['billable_revenue']),
        expectedConversions: _double(json['expected_conversions']),
        expectedDownstreamRevenue: _double(json['expected_downstream_revenue']),
        deliveryCost: _double(json['delivery_cost']),
        platformFee: _double(json['platform_fee']),
        totalCost: _double(json['total_cost']),
        netProfit: _double(json['net_profit']),
        marginPercent: _double(json['margin_percent']),
      );
}

class DashboardMetrics {
  const DashboardMetrics({required this.totalLeads, required this.activeLeads, required this.suppressedLeads, required this.campaigns, required this.dryRunOutreachEvents, required this.liveOutreachEvents, required this.jobsByStatus, required this.pendingAlerts, this.totalReplies = 0, this.interestedReplies = 0, this.pricingReplies = 0, this.meetingReplies = 0, this.reviewedLeads = 0, this.clients = 0, this.projects = 0, this.deliveries = 0, this.bounces = 0, this.replies = 0, this.positiveIntent = 0, this.meetings = 0, this.conversions = 0, this.revenue = 0, this.recurringRevenue = 0, this.failures = 0});

  final int totalLeads;
  final int activeLeads;
  final int suppressedLeads;
  final int campaigns;
  final int dryRunOutreachEvents;
  final int liveOutreachEvents;
  final Map<String, int> jobsByStatus;
  final int pendingAlerts;
  final int totalReplies;
  final int interestedReplies;
  final int pricingReplies;
  final int meetingReplies;
  final int reviewedLeads;
  final int clients;
  final int projects;
  final int deliveries;
  final int bounces;
  final int replies;
  final int positiveIntent;
  final int meetings;
  final int conversions;
  final double revenue;
  final double recurringRevenue;
  final int failures;

  factory DashboardMetrics.fromJson(JsonMap json) => DashboardMetrics(
        totalLeads: _int(json['total_leads']),
        activeLeads: _int(json['active_leads']),
        suppressedLeads: _int(json['suppressed_leads']),
        campaigns: _int(json['campaigns']),
        dryRunOutreachEvents: _int(json['dry_run_outreach_events']),
        liveOutreachEvents: _int(json['live_outreach_events']),
        jobsByStatus: _map(json['jobs_by_status']).map((key, value) => MapEntry(key, _int(value))),
        pendingAlerts: _int(json['pending_alerts']),
        totalReplies: _int(json['total_replies']),
        interestedReplies: _int(json['interested_replies']),
        pricingReplies: _int(json['pricing_replies']),
        meetingReplies: _int(json['meeting_replies']),
        reviewedLeads: _int(json['reviewed_leads']),
        clients: _int(json['clients']),
        projects: _int(json['projects']),
        deliveries: _int(json['deliveries']),
        bounces: _int(json['bounces']),
        replies: _int(json['replies']),
        positiveIntent: _int(json['positive_intent']),
        meetings: _int(json['meetings']),
        conversions: _int(json['conversions']),
        revenue: _double(json['revenue']),
        recurringRevenue: _double(json['recurring_revenue']),
        failures: _int(json['failures']),
      );
}

class PublicSettings {
  const PublicSettings({required this.dryRun, required this.liveSendingEnabled, required this.liveSendReady, required this.provider, required this.providerConfigured, this.senderName, this.senderEmail, required this.physicalAddressConfigured, required this.unsubscribeUrlConfigured, required this.complianceAcknowledged, this.automationPaused = false});

  final bool dryRun;
  final bool liveSendingEnabled;
  final bool liveSendReady;
  final String provider;
  final bool providerConfigured;
  final String? senderName;
  final String? senderEmail;
  final bool physicalAddressConfigured;
  final bool unsubscribeUrlConfigured;
  final bool complianceAcknowledged;
  final bool automationPaused;

  factory PublicSettings.fromJson(JsonMap json) => PublicSettings(
        dryRun: _bool(json['dry_run']),
        liveSendingEnabled: _bool(json['live_sending_enabled']),
        liveSendReady: _bool(json['live_send_ready']),
        provider: _string(json['provider']),
        providerConfigured: _bool(json['provider_configured']),
        senderName: json['sender_name']?.toString(),
        senderEmail: json['sender_email']?.toString(),
        physicalAddressConfigured: _bool(json['physical_address_configured']),
        unsubscribeUrlConfigured: _bool(json['unsubscribe_url_configured']),
        complianceAcknowledged: _bool(json['compliance_acknowledged']),
        automationPaused: _bool(json['automation_paused']),
      );
}

class ProviderStatus {
  const ProviderStatus({required this.name, required this.configured, required this.supportsLiveSend, this.reason});

  final String name;
  final bool configured;
  final bool supportsLiveSend;
  final String? reason;

  factory ProviderStatus.fromJson(JsonMap json) => ProviderStatus(
        name: _string(json['name']),
        configured: _bool(json['configured']),
        supportsLiveSend: _bool(json['supports_live_send']),
        reason: json['reason']?.toString(),
      );
}

class BriefResponse {
  const BriefResponse({required this.prompt, required this.brief});

  final String prompt;
  final String brief;

  factory BriefResponse.fromJson(JsonMap json) => BriefResponse(prompt: _string(json['prompt']), brief: _string(json['brief']));
}

class Alert {
  const Alert({required this.id, required this.severity, required this.message, required this.acknowledged, this.createdAt});

  final int id;
  final String severity;
  final String message;
  final bool acknowledged;
  final DateTime? createdAt;

  factory Alert.fromJson(JsonMap json) => Alert(
        id: _int(json['id']),
        severity: _string(json['severity']),
        message: _string(json['message']),
        acknowledged: _bool(json['acknowledged']),
        createdAt: _date(json['created_at']),
      );
}

class AuditLogEntry {
  const AuditLogEntry({required this.id, required this.action, required this.actor, required this.details, this.createdAt});

  final int id;
  final String action;
  final String actor;
  final JsonMap details;
  final DateTime? createdAt;

  factory AuditLogEntry.fromJson(JsonMap json) => AuditLogEntry(
        id: _int(json['id']),
        action: _string(json['action']),
        actor: _string(json['actor']),
        details: _map(json['details']),
        createdAt: _date(json['created_at']),
      );
}

class HealthResponse {
  const HealthResponse({required this.status, required this.database, required this.migrationVersion});

  final String status;
  final String database;
  final int migrationVersion;

  factory HealthResponse.fromJson(JsonMap json) => HealthResponse(status: _string(json['status']), database: _string(json['database']), migrationVersion: _int(json['migration_version']));
}

class Client {
  const Client({required this.id, required this.companyName, required this.status, this.contactName, this.email, this.leadId, this.notes, this.createdAt, this.updatedAt});

  final int id;
  final String companyName;
  final String status;
  final String? contactName;
  final String? email;
  final int? leadId;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Client.fromJson(JsonMap json) => Client(
        id: _int(json['id']),
        companyName: _string(json['company_name']),
        status: _string(json['status']),
        contactName: json['contact_name']?.toString(),
        email: json['email']?.toString(),
        leadId: json['lead_id'] == null ? null : _int(json['lead_id']),
        notes: json['notes']?.toString(),
        createdAt: _date(json['created_at']),
        updatedAt: _date(json['updated_at']),
      );
}

class Project {
  const Project({required this.id, required this.clientId, required this.name, required this.status, required this.revisionsAllowed, required this.revisionsUsed, this.previewUrl, this.deploymentUrl, this.domain, this.hostingPlan, this.databasePlan, this.createdAt, this.updatedAt});

  final int id;
  final int clientId;
  final String name;
  final String status;
  final String? previewUrl;
  final String? deploymentUrl;
  final String? domain;
  final String? hostingPlan;
  final String? databasePlan;
  final int revisionsAllowed;
  final int revisionsUsed;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Project.fromJson(JsonMap json) => Project(
        id: _int(json['id']),
        clientId: _int(json['client_id']),
        name: _string(json['name']),
        status: _string(json['status']),
        previewUrl: json['preview_url']?.toString(),
        deploymentUrl: json['deployment_url']?.toString(),
        domain: json['domain']?.toString(),
        hostingPlan: json['hosting_plan']?.toString(),
        databasePlan: json['database_plan']?.toString(),
        revisionsAllowed: _int(json['revisions_allowed']),
        revisionsUsed: _int(json['revisions_used']),
        createdAt: _date(json['created_at']),
        updatedAt: _date(json['updated_at']),
      );
}

class AIProviderStatus {
  const AIProviderStatus({required this.name, required this.status, required this.configured, required this.reason, this.model, this.capabilities = const [], this.apiKeyConfigured = false});

  final String name;
  final String status;
  final bool configured;
  final String reason;
  final String? model;
  final List<String> capabilities;
  final bool apiKeyConfigured;

  factory AIProviderStatus.fromJson(JsonMap json) => AIProviderStatus(
        name: _string(json['name']),
        status: _string(json['status']),
        configured: _bool(json['configured']),
        reason: _string(json['reason']),
        model: json['model']?.toString(),
        capabilities: (json['capabilities'] as List? ?? const []).map((item) => item.toString()).toList(),
        apiKeyConfigured: _bool(json['api_key_configured']),
      );
}

class AIProviderConfig {
  const AIProviderConfig({required this.provider, required this.timeoutSeconds, required this.maxRetries, required this.retryBackoffSeconds, required this.apiKeyConfigured, this.model, this.baseUrl, this.configurationErrors = const []});

  final String provider;
  final String? model;
  final String? baseUrl;
  final double timeoutSeconds;
  final int maxRetries;
  final double retryBackoffSeconds;
  final bool apiKeyConfigured;
  final List<String> configurationErrors;

  factory AIProviderConfig.fromJson(JsonMap json) => AIProviderConfig(provider: _string(json['provider']), model: json['model']?.toString(), baseUrl: json['base_url']?.toString(), timeoutSeconds: _double(json['timeout_seconds']), maxRetries: _int(json['max_retries']), retryBackoffSeconds: _double(json['retry_backoff_seconds']), apiKeyConfigured: _bool(json['api_key_configured']), configurationErrors: (json['configuration_errors'] as List? ?? const []).map((item) => item.toString()).toList());
}

class AIConnectivityResult {
  const AIConnectivityResult({required this.status, required this.provider, required this.detail, required this.checkedAt, this.model, this.totalTokens, this.estimatedCostUsd});

  final String status;
  final String provider;
  final String? model;
  final String detail;
  final DateTime checkedAt;
  final int? totalTokens;
  final double? estimatedCostUsd;

  factory AIConnectivityResult.fromJson(JsonMap json) {
    final usage = json['usage'] is Map ? Map<String, dynamic>.from(json['usage'] as Map) : const <String, dynamic>{};
    return AIConnectivityResult(status: _string(json['status']), provider: _string(json['provider']), model: json['model']?.toString(), detail: _string(json['detail']), checkedAt: _date(json['checked_at']) ?? DateTime.now(), totalTokens: usage['total_tokens'] == null ? null : _int(usage['total_tokens']), estimatedCostUsd: usage['estimated_cost_usd'] == null ? null : _double(usage['estimated_cost_usd']));
  }
}

class AIUsageSummary {
  const AIUsageSummary({required this.requests, required this.totalTokens, required this.estimatedCostUsd});

  final int requests;
  final int totalTokens;
  final double estimatedCostUsd;

  factory AIUsageSummary.fromJson(JsonMap json) => AIUsageSummary(requests: _int(json['requests']), totalTokens: _int(json['total_tokens']), estimatedCostUsd: _double(json['estimated_cost_usd']));
}

class AIPersonalizationPreview {
  const AIPersonalizationPreview({required this.provider, required this.model, required this.subject, required this.body, this.summary, this.totalTokens, this.estimatedCostUsd});

  final String provider;
  final String model;
  final String subject;
  final String body;
  final String? summary;
  final int? totalTokens;
  final double? estimatedCostUsd;

  factory AIPersonalizationPreview.fromJson(JsonMap json) {
    final result = _map(json['result']);
    final usage = _map(json['usage']);
    return AIPersonalizationPreview(provider: _string(json['provider']), model: _string(json['model']), subject: _string(result['subject']), body: _string(result['body']), summary: result['personalization_summary']?.toString(), totalTokens: usage['total_tokens'] == null ? null : _int(usage['total_tokens']), estimatedCostUsd: usage['estimated_cost_usd'] == null ? null : _double(usage['estimated_cost_usd']));
  }
}

class GmailStatus {
  const GmailStatus({required this.configured, required this.tokenAvailable, required this.senderEmailConfigured, required this.supportsLiveSend, required this.reason, this.senderEmail, this.health = 'not_checked'});

  final bool configured;
  final bool tokenAvailable;
  final bool senderEmailConfigured;
  final bool supportsLiveSend;
  final String reason;
  final String? senderEmail;
  final String health;

  factory GmailStatus.fromJson(JsonMap json) => GmailStatus(configured: _bool(json['configured']), tokenAvailable: _bool(json['token_available']), senderEmailConfigured: _bool(json['sender_email_configured']), supportsLiveSend: _bool(json['supports_live_send']), reason: _string(json['reason']), senderEmail: json['sender_email']?.toString(), health: _string(json['health']));
}

class GmailSenderIdentity {
  const GmailSenderIdentity({required this.emailAddress, this.messagesTotal, this.threadsTotal});

  final String emailAddress;
  final int? messagesTotal;
  final int? threadsTotal;

  factory GmailSenderIdentity.fromJson(JsonMap json) => GmailSenderIdentity(emailAddress: _string(json['email_address']), messagesTotal: json['messages_total'] == null ? null : _int(json['messages_total']), threadsTotal: json['threads_total'] == null ? null : _int(json['threads_total']));
}

class GmailHealth {
  const GmailHealth({required this.status, required this.detail, this.senderIdentity});

  final String status;
  final String detail;
  final GmailSenderIdentity? senderIdentity;

  bool get isHealthy => status == 'healthy';

  factory GmailHealth.fromJson(JsonMap json) => GmailHealth(status: _string(json['status']), detail: _string(json['detail']), senderIdentity: json['sender_identity'] is Map ? GmailSenderIdentity.fromJson(_map(json['sender_identity'])) : null);
}

class GmailAuthUrl {
  const GmailAuthUrl({required this.authorizationUrl, required this.state});

  final String authorizationUrl;
  final String state;

  factory GmailAuthUrl.fromJson(JsonMap json) => GmailAuthUrl(authorizationUrl: _string(json['authorization_url']), state: _string(json['state']));
}

class GmailReviewedDraft {
  const GmailReviewedDraft({required this.localDraftId, required this.status, this.providerDraftId, this.providerThreadId});

  final String localDraftId;
  final String status;
  final String? providerDraftId;
  final String? providerThreadId;

  bool get isCreated => status == 'created';

  factory GmailReviewedDraft.fromJson(JsonMap json) => GmailReviewedDraft(localDraftId: _string(json['local_draft_id']), status: _string(json['status']), providerDraftId: json['provider_draft_id']?.toString(), providerThreadId: json['provider_thread_id']?.toString());
}

class GmailSyncResult {
  const GmailSyncResult({required this.mode, required this.pages, required this.threadsSeen, this.threadsSkipped = 0, required this.threadsStored, required this.messagesSeen, required this.messagesStored, required this.matched, required this.unknown, required this.ambiguous, this.nextPageToken, this.historyId});

  final String mode;
  final int pages;
  final int threadsSeen;
  final int threadsSkipped;
  final int threadsStored;
  final int messagesSeen;
  final int messagesStored;
  final int matched;
  final int unknown;
  final int ambiguous;
  final String? nextPageToken;
  final String? historyId;

  bool get isEmpty => threadsSeen == 0 && messagesSeen == 0;

  factory GmailSyncResult.fromJson(JsonMap json) => GmailSyncResult(mode: _string(json['mode']), pages: _int(json['pages']), threadsSeen: _int(json['threads_seen']), threadsSkipped: _int(json['threads_skipped']), threadsStored: _int(json['threads_stored']), messagesSeen: _int(json['messages_seen']), messagesStored: _int(json['messages_stored']), matched: _int(json['matched']), unknown: _int(json['unknown']), ambiguous: _int(json['ambiguous']), nextPageToken: json['next_page_token']?.toString(), historyId: json['history_id']?.toString());
}

class GmailThread {
  const GmailThread({required this.threadId, this.snippet, this.historyId});

  final String threadId;
  final String? snippet;
  final String? historyId;

  factory GmailThread.fromJson(JsonMap json) => GmailThread(threadId: _string(json['thread_id']), snippet: json['snippet']?.toString(), historyId: json['history_id']?.toString());
}

class GmailDisconnect {
  const GmailDisconnect({required this.status, required this.providerRevoked});

  final String status;
  final bool providerRevoked;

  factory GmailDisconnect.fromJson(JsonMap json) => GmailDisconnect(status: _string(json['status']), providerRevoked: _bool(json['provider_revoked']));
}

class WebsitePackage {
  const WebsitePackage({required this.id, required this.name, required this.setupPrice, required this.hostingMonthlyRevenue, required this.maintenanceMonthlyRevenue, required this.active, this.description, this.deliveryLaborCost = 0, this.aiApiCost = 0, this.domainCost = 0, this.databaseCost = 0, this.liabilityCost = 0, this.otherCost = 0, this.createdAt, this.updatedAt});

  final int id;
  final String name;
  final double setupPrice;
  final double hostingMonthlyRevenue;
  final double maintenanceMonthlyRevenue;
  final bool active;
  final String? description;
  final double deliveryLaborCost;
  final double aiApiCost;
  final double domainCost;
  final double databaseCost;
  final double liabilityCost;
  final double otherCost;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory WebsitePackage.fromJson(JsonMap json) => WebsitePackage(id: _int(json['id']), name: _string(json['name']), setupPrice: _double(json['setup_price']), hostingMonthlyRevenue: _double(json['hosting_monthly_revenue']), maintenanceMonthlyRevenue: _double(json['maintenance_monthly_revenue']), active: _bool(json['active']), description: json['description']?.toString(), deliveryLaborCost: _double(json['delivery_labor_cost']), aiApiCost: _double(json['ai_api_cost']), domainCost: _double(json['domain_cost']), databaseCost: _double(json['database_cost']), liabilityCost: _double(json['liability_cost']), otherCost: _double(json['other_cost']), createdAt: _date(json['created_at']), updatedAt: _date(json['updated_at']));
}

class PackageProfitResult {
  const PackageProfitResult({this.packageId, required this.setupRevenue, required this.hostingMonthlyRevenue, required this.maintenanceMonthlyRevenue, required this.monthlyRecurringRevenue, required this.upfrontCost, required this.upfrontProfit, required this.firstYearRevenue, required this.firstYearCost, required this.firstYearProfit, required this.firstYearMarginPercent, required this.months});

  final int? packageId;
  final double setupRevenue;
  final double hostingMonthlyRevenue;
  final double maintenanceMonthlyRevenue;
  final double monthlyRecurringRevenue;
  final double upfrontCost;
  final double upfrontProfit;
  final double firstYearRevenue;
  final double firstYearCost;
  final double firstYearProfit;
  final double firstYearMarginPercent;
  final int months;

  factory PackageProfitResult.fromJson(JsonMap json) => PackageProfitResult(packageId: json['package_id'] == null ? null : _int(json['package_id']), setupRevenue: _double(json['setup_revenue']), hostingMonthlyRevenue: _double(json['hosting_monthly_revenue']), maintenanceMonthlyRevenue: _double(json['maintenance_monthly_revenue']), monthlyRecurringRevenue: _double(json['monthly_recurring_revenue']), upfrontCost: _double(json['upfront_cost']), upfrontProfit: _double(json['upfront_profit']), firstYearRevenue: _double(json['first_year_revenue']), firstYearCost: _double(json['first_year_cost']), firstYearProfit: _double(json['first_year_profit']), firstYearMarginPercent: _double(json['first_year_margin_percent']), months: _int(json['months']));
}
