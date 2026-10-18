CREATE TABLE IF NOT EXISTS website_packages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    description TEXT,
    setup_price REAL NOT NULL DEFAULT 0 CHECK (setup_price >= 0),
    hosting_monthly_revenue REAL NOT NULL DEFAULT 0 CHECK (hosting_monthly_revenue >= 0),
    maintenance_monthly_revenue REAL NOT NULL DEFAULT 0 CHECK (maintenance_monthly_revenue >= 0),
    delivery_labor_cost REAL NOT NULL DEFAULT 0 CHECK (delivery_labor_cost >= 0),
    ai_api_cost REAL NOT NULL DEFAULT 0 CHECK (ai_api_cost >= 0),
    domain_cost REAL NOT NULL DEFAULT 0 CHECK (domain_cost >= 0),
    database_cost REAL NOT NULL DEFAULT 0 CHECK (database_cost >= 0),
    liability_cost REAL NOT NULL DEFAULT 0 CHECK (liability_cost >= 0),
    other_cost REAL NOT NULL DEFAULT 0 CHECK (other_cost >= 0),
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_website_packages_active ON website_packages(active);

CREATE TABLE IF NOT EXISTS follow_up_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    campaign_id INTEGER NOT NULL REFERENCES campaigns(id),
    lead_id INTEGER NOT NULL REFERENCES leads(id),
    sequence_number INTEGER NOT NULL DEFAULT 1 CHECK (sequence_number >= 1),
    scheduled_for TEXT NOT NULL,
    provider TEXT,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    dry_run INTEGER NOT NULL DEFAULT 1 CHECK (dry_run = 1),
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    executed_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_follow_up_queue_schedule ON follow_up_queue(status, scheduled_for);
CREATE INDEX IF NOT EXISTS idx_follow_up_queue_lead ON follow_up_queue(lead_id);
