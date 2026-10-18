from __future__ import annotations

from ..models import DashboardMetrics
from ..repositories import AlertRepository, CampaignRepository, ClientRepository, JobRepository, LeadRepository, OutreachRepository, ReplyRepository
from ..repositories_sales import SalesMetricsRepository


class MetricsService:
    def __init__(self, leads: LeadRepository, campaigns: CampaignRepository, events: OutreachRepository, jobs: JobRepository, alerts: AlertRepository, replies: ReplyRepository, clients: ClientRepository, sales: SalesMetricsRepository):
        self.leads = leads
        self.campaigns = campaigns
        self.events = events
        self.jobs = jobs
        self.alerts = alerts
        self.replies = replies
        self.clients = clients
        self.sales = sales

    def dashboard(self) -> DashboardMetrics:
        return DashboardMetrics(
            total_leads=self.leads.count(),
            active_leads=self.leads.active_count(),
            suppressed_leads=self.leads.suppression_count(),
            campaigns=len(self.campaigns.list()),
            dry_run_outreach_events=self.events.count(True),
            live_outreach_events=self.events.count(False),
            jobs_by_status=self.jobs.status_counts(),
            pending_alerts=self.alerts.pending_count(),
            total_replies=self.replies.count(),
            interested_replies=self.replies.count("interested"),
            pricing_replies=self.replies.count("pricing"),
            meeting_replies=self.replies.count("meeting"),
            reviewed_leads=self.leads.count_status("reviewed"),
            clients=self.clients.count("clients"),
            projects=self.clients.count("projects"),
            deliveries=self.events.count_status("sent") + self.events.count_status("dry_run"),
            bounces=self.replies.count("bounce"),
            replies=self.replies.count(),
            positive_intent=self.replies.count_classifications(("interested", "pricing", "meeting")),
            meetings=self.replies.count("meeting"),
            conversions=self.sales.conversions(),
            revenue=self.sales.revenue(),
            recurring_revenue=self.sales.recurring_revenue(),
            failures=self.events.count_status("failed"),
        )
