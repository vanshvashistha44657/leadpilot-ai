CREATE TABLE IF NOT EXISTS import_batches (
    id TEXT PRIMARY KEY,
    filename TEXT NOT NULL,
    file_type TEXT NOT NULL,
    status TEXT NOT NULL,
    rows_processed INTEGER NOT NULL DEFAULT 0,
    imported_count INTEGER NOT NULL DEFAULT 0,
    duplicate_count INTEGER NOT NULL DEFAULT 0,
    suppressed_count INTEGER NOT NULL DEFAULT 0,
    invalid_count INTEGER NOT NULL DEFAULT 0,
    skipped_count INTEGER NOT NULL DEFAULT 0,
    error_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    finished_at TEXT,
    error TEXT
);

CREATE TABLE IF NOT EXISTS import_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id TEXT NOT NULL REFERENCES import_batches(id),
    row_number INTEGER NOT NULL,
    field_name TEXT,
    error_code TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS lead_import_sources (
    lead_id INTEGER NOT NULL REFERENCES leads(id),
    batch_id TEXT NOT NULL REFERENCES import_batches(id),
    source_row INTEGER NOT NULL,
    source_label TEXT,
    imported_at TEXT NOT NULL,
    PRIMARY KEY (lead_id, batch_id)
);

CREATE TABLE IF NOT EXISTS outreach_drafts (
    id TEXT PRIMARY KEY,
    lead_id INTEGER NOT NULL REFERENCES leads(id),
    status TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    subject TEXT NOT NULL,
    body TEXT NOT NULL,
    generated_subject TEXT NOT NULL,
    generated_body TEXT NOT NULL,
    offer TEXT NOT NULL,
    tone TEXT NOT NULL,
    call_to_action TEXT NOT NULL,
    request_id TEXT,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    estimated_cost_usd REAL,
    error TEXT,
    generated_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (lead_id)
);

CREATE INDEX IF NOT EXISTS idx_import_errors_batch ON import_errors(batch_id);
CREATE INDEX IF NOT EXISTS idx_drafts_status ON outreach_drafts(status);
CREATE INDEX IF NOT EXISTS idx_drafts_lead ON outreach_drafts(lead_id);
