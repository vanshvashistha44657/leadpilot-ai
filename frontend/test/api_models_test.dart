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
}
