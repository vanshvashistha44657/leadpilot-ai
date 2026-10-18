CREATE INDEX IF NOT EXISTS idx_leads_research_status ON leads(research_status);
CREATE INDEX IF NOT EXISTS idx_leads_opportunity_score ON leads(opportunity_score);

CREATE TABLE IF NOT EXISTS reply_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lead_id INTEGER NOT NULL REFERENCES leads(id),
    provider TEXT NOT NULL,
    subject TEXT,
    body TEXT NOT NULL,
    classification TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_reply_events_lead ON reply_events(lead_id);
CREATE INDEX IF NOT EXISTS idx_reply_events_classification ON reply_events(classification);

CREATE TABLE IF NOT EXISTS clients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lead_id INTEGER REFERENCES leads(id),
    company_name TEXT NOT NULL,
    contact_name TEXT,
    email TEXT,
    status TEXT NOT NULL DEFAULT 'prospect',
    notes TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_clients_status ON clients(status);

CREATE TABLE IF NOT EXISTS proposals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    status TEXT NOT NULL DEFAULT 'draft',
    amount REAL NOT NULL DEFAULT 0,
    recurring_amount REAL NOT NULL DEFAULT 0,
    valid_until TEXT,
    notes TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_proposals_client ON proposals(client_id);

CREATE TABLE IF NOT EXISTS projects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'intake',
    preview_url TEXT,
    deployment_url TEXT,
    domain TEXT,
    hosting_plan TEXT,
    database_plan TEXT,
    revisions_allowed INTEGER NOT NULL DEFAULT 2,
    revisions_used INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_projects_client ON projects(client_id);

CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    proposal_id INTEGER REFERENCES proposals(id),
    amount REAL NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'pending',
    paid_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS renewals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    project_id INTEGER REFERENCES projects(id),
    due_at TEXT NOT NULL,
    amount REAL NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'upcoming',
    created_at TEXT NOT NULL
);
