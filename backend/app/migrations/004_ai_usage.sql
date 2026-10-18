CREATE TABLE IF NOT EXISTS ai_usage_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation TEXT NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    request_id TEXT,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    estimated_cost_usd REAL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ai_usage_created_at ON ai_usage_events(created_at);
CREATE INDEX IF NOT EXISTS idx_ai_usage_operation ON ai_usage_events(operation);
