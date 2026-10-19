CREATE TABLE IF NOT EXISTS gmail_accounts (
    account_id TEXT PRIMARY KEY,
    email TEXT,
    scopes_json TEXT NOT NULL DEFAULT '[]',
    status TEXT NOT NULL DEFAULT 'disconnected',
    last_error TEXT,
    connected_at TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS gmail_draft_references (
    local_draft_id TEXT PRIMARY KEY REFERENCES outreach_drafts(id),
    lead_id INTEGER NOT NULL REFERENCES leads(id),
    idempotency_key TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL,
    provider_draft_id TEXT,
    provider_thread_id TEXT,
    error_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_gmail_draft_refs_status ON gmail_draft_references(status);
CREATE INDEX IF NOT EXISTS idx_gmail_draft_refs_lead ON gmail_draft_references(lead_id);

CREATE TABLE IF NOT EXISTS gmail_sync_state (
    account_id TEXT PRIMARY KEY,
    history_id TEXT,
    page_token TEXT,
    last_sync_at TEXT,
    last_error TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS gmail_threads (
    provider_thread_id TEXT PRIMARY KEY,
    history_id TEXT,
    snippet TEXT,
    synced_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS gmail_messages (
    provider_message_id TEXT PRIMARY KEY,
    provider_thread_id TEXT NOT NULL REFERENCES gmail_threads(provider_thread_id),
    lead_id INTEGER REFERENCES leads(id),
    match_status TEXT NOT NULL,
    from_email TEXT,
    to_emails_json TEXT NOT NULL DEFAULT '[]',
    subject TEXT,
    snippet TEXT,
    body TEXT,
    internal_date TEXT,
    synced_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(provider_thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_lead ON gmail_messages(lead_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_match ON gmail_messages(match_status);
