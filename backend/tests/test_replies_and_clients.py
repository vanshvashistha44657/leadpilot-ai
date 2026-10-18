from __future__ import annotations


HEADERS = {"X-Local-Token": "test-token"}


def test_reply_ingest_suppresses_opt_out_and_creates_alert(client):
    lead = client.post(
        "/api/leads",
        headers=HEADERS,
        json={"email": "owner@acme.example", "company": "Acme", "first_name": "Sam"},
    )
    assert lead.status_code == 201

    response = client.post(
        "/api/replies/ingest",
        headers=HEADERS,
        json={"email": "owner@acme.example", "subject": "Re: hello", "body": "Please unsubscribe me."},
    )
    assert response.status_code == 201
    assert response.json()["classification"] == "unsubscribe"

    stored = client.get("/api/leads", headers=HEADERS).json()[0]
    assert stored["status"] == "unsubscribed"
    assert client.get("/api/suppressions", headers=HEADERS).json()[0]["normalized_email"] == "owner@acme.example"


def test_high_intent_reply_alerts_and_followups_are_stopped(client):
    lead = client.post(
        "/api/leads",
        headers=HEADERS,
        json={"email": "buyer@acme.example", "company": "Acme"},
    )
    assert lead.status_code == 201
    lead_id = lead.json()["id"]

    reply = client.post(
        "/api/replies/ingest",
        headers=HEADERS,
        json={"email": "buyer@acme.example", "body": "Interested. Can we schedule a meeting?"},
    )
    assert reply.json()["classification"] in {"meeting", "interested"}
    assert client.get("/api/alerts", headers=HEADERS).json()

    campaign = client.post("/api/campaigns", headers=HEADERS, json={"name": "Follow-up"}).json()
    preview = client.post(
        f"/api/campaigns/{campaign['id']}/outreach/preview",
        headers=HEADERS,
        json={"subject": "Hello", "body_template": "Hi", "lead_ids": [lead_id]},
    )
    assert preview.status_code == 200
    assert preview.json()["items"] == []


def test_client_project_and_verified_research_workflow(client):
    lead = client.post(
        "/api/leads",
        headers=HEADERS,
        json={"email": "owner@studio.example", "company": "Studio", "title": "Owner"},
    ).json()
    research = client.post(
        f"/api/leads/{lead['id']}/research",
        headers=HEADERS,
        json={"website_url": "https://studio.example", "verified_notes": "Operator verified the URL."},
    )
    assert research.status_code == 200
    assert research.json()["opportunity_score"] > 0

    client_response = client.post(
        "/api/clients",
        headers=HEADERS,
        json={"company_name": "Studio", "contact_name": "Owner", "lead_id": lead["id"]},
    )
    assert client_response.status_code == 201
    project = client.post(
        "/api/projects",
        headers=HEADERS,
        json={"client_id": client_response.json()["id"], "name": "Studio website"},
    )
    assert project.status_code == 201
    metrics = client.get("/api/dashboard/metrics", headers=HEADERS).json()
    assert metrics["clients"] == 1
    assert metrics["projects"] == 1
