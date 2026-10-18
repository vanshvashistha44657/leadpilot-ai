from __future__ import annotations

import time


def auth_headers() -> dict[str, str]:
    return {"X-Local-Token": "test-token"}


def wait_for_job(client, job_id: str) -> dict:
    for _ in range(50):
        response = client.get(f"/api/jobs/{job_id}", headers=auth_headers())
        assert response.status_code == 200
        job = response.json()
        if job["status"] in {"completed", "failed", "cancelled"}:
            return job
        time.sleep(0.01)
    raise AssertionError("job did not finish")


def test_local_token_is_required(client):
    response = client.get("/api/dashboard/metrics")
    assert response.status_code == 401


def test_outreach_defaults_to_dry_run_and_live_is_blocked(client):
    lead = client.post(
        "/api/leads",
        headers=auth_headers(),
        json={"email": "person@example.com", "first_name": "Person", "company": "Example"},
    )
    assert lead.status_code == 201
    campaign = client.post("/api/campaigns", headers=auth_headers(), json={"name": "Safe campaign"})
    assert campaign.status_code == 201
    campaign_id = campaign.json()["id"]
    body = {"subject": "Hello {{first_name}}", "body_template": "Hi {first_name} at {company}"}

    preview = client.post(f"/api/campaigns/{campaign_id}/outreach/preview", headers=auth_headers(), json=body)
    assert preview.status_code == 200
    assert preview.json()["dry_run"] is True
    assert preview.json()["items"][0]["body"] == "Hi Person at Example"

    queued = client.post(f"/api/campaigns/{campaign_id}/outreach/run", headers=auth_headers(), json=body)
    assert queued.status_code == 202
    job = wait_for_job(client, queued.json()["id"])
    assert job["status"] == "completed"
    assert job["result"]["dry_run"] is True
    assert client.app.state.services.events.count(True) == 1
    assert client.app.state.services.events.count(False) == 0
    detail = client.get(f"/api/leads/{lead.json()['id']}", headers=auth_headers())
    assert detail.status_code == 200
    history = client.get(f"/api/leads/{lead.json()['id']}/history", headers=auth_headers())
    assert history.status_code == 200
    assert history.json()[0]["status"] == "dry_run"

    blocked = client.post(
        f"/api/campaigns/{campaign_id}/outreach/run",
        headers=auth_headers(),
        json={**body, "live": True},
    )
    assert blocked.status_code == 409
    assert "dry-run" in blocked.json()["detail"] or "campaign" in blocked.json()["detail"]


def test_provider_stubs_do_not_claim_configuration_without_credentials(client, monkeypatch):
    for key in ("GMAIL_CLIENT_ID", "GMAIL_CLIENT_SECRET", "GMAIL_REFRESH_TOKEN", "GMAIL_SENDER_EMAIL"):
        monkeypatch.delenv(key, raising=False)
    providers = client.get("/api/providers", headers=auth_headers())
    assert providers.status_code == 200
    statuses = {item["name"]: item for item in providers.json()}
    assert statuses["gmail"]["configured"] is False
    assert statuses["graph"]["configured"] is False
    assert statuses["gmail"]["supports_live_send"] is False
    assert statuses["graph"]["supports_live_send"] is False


def test_global_stop_blocks_new_automation(client):
    stopped = client.post("/api/automation/stop", headers=auth_headers())
    assert stopped.status_code == 200
    assert stopped.json()["automation_paused"] is True

    campaign = client.post("/api/campaigns", headers=auth_headers(), json={"name": "Paused"}).json()
    queued = client.post(
        f"/api/campaigns/{campaign['id']}/outreach/run",
        headers=auth_headers(),
        json={"subject": "Hello", "body_template": "Hi"},
    )
    assert queued.status_code == 409
    assert "paused" in queued.json()["detail"]

    resumed = client.post("/api/automation/resume", headers=auth_headers())
    assert resumed.status_code == 200
    assert resumed.json()["automation_paused"] is False


def test_large_import_can_be_queued(client):
    response = client.post(
        "/api/leads/import/queue",
        headers=auth_headers(),
        files={"file": ("leads.csv", b"email,company\nqueued@example.com,Queued\n", "text/csv")},
    )
    assert response.status_code == 202
    job = wait_for_job(client, response.json()["id"])
    assert job["status"] == "completed"
    assert job["result"]["imported"] == 1
    assert client.get("/api/leads", headers=auth_headers()).json()[0]["email"] == "queued@example.com"
    incoming = client.app.state.services.database.path.parent / "incoming"
    assert not list(incoming.glob("*"))


def test_provider_credentials_do_not_enable_unimplemented_live_send(client, monkeypatch):
    for key, value in {
        "GMAIL_CLIENT_ID": "id",
        "GMAIL_CLIENT_SECRET": "secret",
        "GMAIL_REFRESH_TOKEN": "refresh",
        "GMAIL_SENDER_EMAIL": "sender@example.com",
    }.items():
        monkeypatch.setenv(key, value)
    providers = {item["name"]: item for item in client.get("/api/providers", headers=auth_headers()).json()}
    assert providers["gmail"]["configured"] is True
    assert providers["gmail"]["supports_live_send"] is False
    assert client.get("/api/settings", headers=auth_headers()).json()["live_send_ready"] is False


def test_pagination_suppression_pricing_and_backup_survive_api_round_trip(client):
    for index in range(3):
        response = client.post(
            "/api/leads",
            headers=auth_headers(),
            json={"email": f"owner{index}@example.com", "company": f"Company {index}"},
        )
        assert response.status_code == 201

    page = client.get("/api/leads", headers=auth_headers(), params={"limit": 1, "offset": 1, "search": "Company"})
    assert page.status_code == 200
    assert len(page.json()) == 1
    assert client.get("/api/leads/count", headers=auth_headers(), params={"search": "Company"}).json()["total"] == 3

    suppressed = client.post(
        "/api/suppressions",
        headers=auth_headers(),
        json={"email": "owner1@example.com", "reason": "manual opt-out"},
    )
    assert suppressed.status_code == 201
    detail = client.get(f"/api/leads/{page.json()[0]['id']}", headers=auth_headers())
    assert detail.status_code == 200

    pricing = client.post(
        "/api/pricing/calculate",
        headers=auth_headers(),
        json={"leads": 10, "price_per_lead": 100, "expected_close_rate": 0.2, "revenue_per_conversion": 500, "email_cost_per_lead": 2, "labor_cost": 100, "other_cost": 25, "platform_fee_percent": 5},
    )
    assert pricing.status_code == 200
    assert pricing.json()["net_profit"] == 805.0

    backup = client.post("/api/backup", headers=auth_headers())
    assert backup.status_code == 200
    assert int(backup.json()["size_bytes"]) > 0
