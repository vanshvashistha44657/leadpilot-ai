import 'package:flutter_test/flutter_test.dart';

import 'package:leadpilot_frontend/core/models/api_models.dart';

void main() {
  test('Lead parses persisted research fields and normalizes display data', () {
    final lead = Lead.fromJson({
      'id': 7,
      'email': 'owner@example.com',
      'normalized_email': 'owner@example.com',
      'first_name': 'Ada',
      'last_name': 'Lovelace',
      'company': 'Analytical Engines',
      'title': 'Owner',
      'source': 'csv',
      'metadata': <String, dynamic>{'state': 'CA'},
      'status': 'reviewed',
      'opportunity_score': 75,
      'research_status': 'reviewed',
      'website_url': 'https://example.com',
      'research_notes': 'Operator verified',
      'created_at': '2026-01-01T12:00:00Z',
      'updated_at': '2026-01-01T12:00:00Z',
    });

    expect(lead.displayName, 'Ada Lovelace');
    expect(lead.opportunityScore, 75);
    expect(lead.researchStatus, 'reviewed');
    expect(lead.websiteUrl, 'https://example.com');
  });

  test('DashboardMetrics tolerates optional counters from older backends', () {
    final metrics = DashboardMetrics.fromJson({
      'total_leads': 2,
      'active_leads': 2,
      'suppressed_leads': 0,
      'campaigns': 1,
      'dry_run_outreach_events': 1,
      'live_outreach_events': 0,
      'jobs_by_status': {'completed': 1},
      'pending_alerts': 0,
    });

    expect(metrics.totalLeads, 2);
    expect(metrics.totalReplies, 0);
    expect(metrics.jobsByStatus['completed'], 1);
  });

  test('AI configuration and connectivity results keep secrets out of display models', () {
    final config = AIProviderConfig.fromJson({
      'provider': 'openai-compatible',
      'model': 'test-model',
      'base_url': 'https://api.example.test/v1',
      'timeout_seconds': 20,
      'max_retries': 2,
      'retry_backoff_seconds': 0.25,
      'api_key_configured': true,
      'configuration_errors': <String>[],
    });
    final result = AIConnectivityResult.fromJson({
      'status': 'connected',
      'provider': 'openai-compatible',
      'model': 'test-model',
      'detail': 'Provider accepted the connectivity check.',
      'checked_at': '2026-01-01T12:00:00Z',
      'usage': {'total_tokens': 4, 'estimated_cost_usd': 0.001},
    });

    expect(config.apiKeyConfigured, isTrue);
    expect(config.retryBackoffSeconds, 0.25);
    expect(result.status, 'connected');
    expect(result.totalTokens, 4);
    expect(result.detail, isNot(contains('secret')));
  });

  test('Import preview exposes mapping/errors and draft models preserve generated content', () {
    final preview = ImportPreview.fromJson({
      'filename': 'leads.xlsx',
      'file_type': 'xlsx',
      'columns': ['Email', 'Company'],
      'suggested_mapping': {'Email': 'email', 'Company': 'company'},
      'sample_rows': [{'Email': 'a@example.com', 'Company': 'Acme'}],
      'row_count': 10,
      'limit_exceeded': false,
      'errors': ['row 4: invalid email'],
    });
    final draft = PersonalizedDraft.fromJson({
      'id': 'draft-1',
      'lead_id': 3,
      'status': 'edited',
      'provider': 'test-llm',
      'model': 'test-model',
      'subject': 'Edited subject',
      'body': 'Edited body',
      'generated_subject': 'AI subject',
      'generated_body': 'AI body',
      'offer': 'websites',
      'tone': 'professional',
      'call_to_action': 'Reply',
      'generated_at': '2026-01-01T12:00:00Z',
      'updated_at': '2026-01-01T12:01:00Z',
    });

    expect(preview.suggestedMapping['Email'], 'email');
    expect(preview.errors, contains('row 4: invalid email'));
    expect(draft.status, 'edited');
    expect(draft.generatedBody, 'AI body');
    expect(draft.body, 'Edited body');
  });
}
