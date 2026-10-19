from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from app.db import Database
from app.models import PackageRecommendationRequest
from app.services.sales import calculate_package_profit, recommend_packages


HEADERS = {"X-Local-Token": "test-token"}


def test_sales_migration_is_versioned_and_repeatable(tmp_path: Path):
    database = Database(tmp_path / "sales.db")

    assert database.initialize() == 6
    assert database.initialize() == 6
    with database.session() as connection:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        proposal_columns = {row[1] for row in connection.execute("PRAGMA table_info(proposals)")}
        versions = [row[0] for row in connection.execute("SELECT version FROM schema_version ORDER BY version")]

    assert {"website_packages", "follow_up_queue"}.issubset(tables)
    assert {
        "package_id",
        "ai_api_cost",
        "domain_cost",
        "database_cost",
        "liability_cost",
    }.issubset(proposal_columns)
    assert versions == [1, 2, 3, 4, 5, 6]


def test_package_profit_includes_recurring_revenue_and_all_cost_fields():
    result = calculate_package_profit(
        {
            "id": 7,
            "setup_price": 3000,
            "hosting_monthly_revenue": 100,
            "maintenance_monthly_revenue": 150,
            "delivery_labor_cost": 900,
            "ai_api_cost": 100,
            "domain_cost": 25,
            "database_cost": 75,
            "liability_cost": 50,
            "other_cost": 50,
        }
    )

    assert result.package_id == 7
    assert result.monthly_recurring_revenue == 250
    assert result.upfront_cost == 1200
    assert result.upfront_profit == 1800
    assert result.first_year_revenue == 6000
    assert result.first_year_profit == 4800
    assert result.first_year_margin_percent == 80


def test_package_recommendations_have_deterministic_profit_order():
    packages = [
        {"id": 2, "name": "Standard", "setup_price": 1000, "hosting_monthly_revenue": 50, "active": True},
        {"id": 1, "name": "Premium", "setup_price": 1500, "hosting_monthly_revenue": 100, "active": True},
        {"id": 3, "name": "Inactive", "setup_price": 5000, "active": False},
    ]

    result = recommend_packages(
        packages,
        PackageRecommendationRequest(requires_hosting=True),
    )

    assert [item["id"] for item in result] == [1, 2]
    assert result[0]["first_year_profit"] == 2700


def test_package_routes_validate_financials_and_snapshot_package_into_proposal(client):
    package = client.post(
        "/api/packages",
        headers=HEADERS,
        json={
            "name": "Managed site",
            "setup_price": 3000,
            "hosting_monthly_revenue": 100,
            "maintenance_monthly_revenue": 150,
            "ai_api_cost": 100,
            "domain_cost": 25,
            "database_cost": 75,
            "liability_cost": 50,
        },
    )
    assert package.status_code == 201
    package_data = package.json()

    profit = client.post(
        f"/api/packages/{package_data['id']}/profit",
        headers=HEADERS,
    )
    assert profit.status_code == 200
    assert profit.json()["monthly_recurring_revenue"] == 250
    assert profit.json()["first_year_profit"] == 5750

    recommendation = client.post(
        "/api/packages/recommend",
        headers=HEADERS,
        json={"requires_hosting": True, "requires_maintenance": True},
    )
    assert recommendation.status_code == 200
    assert recommendation.json()["recommendations"][0]["id"] == package_data["id"]

    customer = client.post(
        "/api/clients",
        headers=HEADERS,
        json={"company_name": "Managed customer"},
    ).json()
    proposal = client.post(
        "/api/proposals",
        headers=HEADERS,
        json={"client_id": customer["id"], "package_id": package_data["id"]},
    )
    assert proposal.status_code == 201
    assert proposal.json()["amount"] == 3000
    assert proposal.json()["recurring_amount"] == 250
    assert proposal.json()["database_cost"] == 75


def test_follow_up_queue_excludes_reply_bounce_and_unsubscribe_and_stays_dry_run(client):
    leads = {}
    for key in ("eligible", "replied", "bounced", "unsubscribed"):
        response = client.post(
            "/api/leads",
            headers=HEADERS,
            json={"email": f"{key}@example.com", "first_name": key.title()},
        )
        assert response.status_code == 201
        leads[key] = response.json()["id"]

    for key, body in {
        "replied": "Tell me more, please.",
        "bounced": "Delivery failed for this mailbox.",
        "unsubscribed": "Please unsubscribe me.",
    }.items():
        response = client.post(
            "/api/replies/ingest",
            headers=HEADERS,
            json={"email": f"{key}@example.com", "body": body},
        )
        assert response.status_code == 201

    campaign = client.post("/api/campaigns", headers=HEADERS, json={"name": "Follow-up queue"}).json()
    response = client.post(
        "/api/follow-ups/queue",
        headers=HEADERS,
        json={
            "campaign_id": campaign["id"],
            "subject": "Checking in with {{first_name}}",
            "body_template": "Hi {{first_name}}",
            "lead_ids": list(leads.values()),
            "scheduled_for": "2030-01-01T12:00:00+00:00",
        },
    )

    assert response.status_code == 201
    queued = response.json()
    assert [item["lead_id"] for item in queued] == [leads["eligible"]]
    assert queued[0]["dry_run"] is True
    assert client.app.state.services.events.count() == 0

    rejected = client.post(
        "/api/follow-ups/queue",
        headers=HEADERS,
        json={
            "campaign_id": campaign["id"],
            "subject": "No live follow-up",
            "body_template": "Hi",
            "scheduled_for": "2030-01-01T12:00:00+00:00",
            "dry_run": False,
        },
    )
    assert rejected.status_code == 422


def test_dashboard_counts_delivery_reply_intent_meeting_conversion_revenue_and_failures(client):
    delivery = client.post(
        "/api/leads", headers=HEADERS, json={"email": "delivery@example.com", "company": "Delivery"}
    ).json()
    reply = client.post(
        "/api/leads", headers=HEADERS, json={"email": "reply@example.com", "company": "Reply"}
    ).json()
    bounce = client.post(
        "/api/leads", headers=HEADERS, json={"email": "bounce@example.com", "company": "Bounce"}
    ).json()
    meeting = client.post(
        "/api/leads", headers=HEADERS, json={"email": "meeting@example.com", "company": "Meeting"}
    ).json()

    campaign = client.post("/api/campaigns", headers=HEADERS, json={"name": "Metrics"}).json()
    client.app.state.services.events.create(
        campaign["id"], delivery["id"], "mock", "dry_run", "Hello", "Hi", True
    )
    client.app.state.services.events.create(
        campaign["id"], reply["id"], "mock", "failed", "Hello", "Hi", True, error="test failure"
    )
    client.post(
        "/api/replies/ingest",
        headers=HEADERS,
        json={"email": "reply@example.com", "body": "Interested, tell me more."},
    )
    client.post(
        "/api/replies/ingest",
        headers=HEADERS,
        json={"email": "bounce@example.com", "body": "Delivery failed."},
    )
    client.post(
        "/api/replies/ingest",
        headers=HEADERS,
        json={"email": "meeting@example.com", "body": "Can we schedule a meeting?"},
    )

    customer = client.post(
        "/api/clients",
        headers=HEADERS,
        json={"company_name": "Won customer", "status": "won"},
    ).json()
    client.post(
        "/api/payments",
        headers=HEADERS,
        json={"client_id": customer["id"], "amount": 2500, "status": "paid"},
    )
    proposal = client.post(
        "/api/proposals",
        headers=HEADERS,
        json={
            "client_id": customer["id"],
            "status": "accepted",
            "amount": 2500,
            "recurring_amount": 300,
        },
    )
    assert proposal.status_code == 201

    metrics = client.get("/api/dashboard/metrics", headers=HEADERS)
    assert metrics.status_code == 200
    values = metrics.json()
    assert values["deliveries"] == 1
    assert values["bounces"] == 1
    assert values["replies"] == 3
    assert values["positive_intent"] == 2
    assert values["meetings"] == 1
    assert values["conversions"] == 1
    assert values["revenue"] == 2500
    assert values["recurring_revenue"] == 300
    assert values["failures"] == 1
