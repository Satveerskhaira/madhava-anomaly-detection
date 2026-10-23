-- Cloud SQL for PostgreSQL in VPC 2. Holds review state only; anomaly data stays in BigQuery.
-- Flyway naming (V1__...). Keys match BigQuery ids: flag_id = md5(client|window), claim_id from claims.

CREATE TABLE IF NOT EXISTS flag_review (
    flag_id       text        PRIMARY KEY,
    client_id     text        NOT NULL,
    window_start  timestamptz NOT NULL,
    status        text        NOT NULL DEFAULT 'NEW'
                  CHECK (status IN ('NEW', 'IN_REVIEW', 'CONFIRMED', 'FALSE_POSITIVE', 'NO_ACTION')),
    assignee      text,
    note          text,
    updated_by    text        NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS flag_review_client_window ON flag_review (client_id, window_start DESC);
CREATE INDEX IF NOT EXISTS flag_review_status        ON flag_review (status) WHERE status IN ('NEW', 'IN_REVIEW');

CREATE TABLE IF NOT EXISTS claim_review (
    flag_id       text        NOT NULL,
    claim_id      text        NOT NULL,
    status        text        NOT NULL DEFAULT 'NEW'
                  CHECK (status IN ('NEW', 'REVIEWED', 'CONFIRMED', 'FALSE_POSITIVE')),
    note          text,
    updated_by    text        NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (flag_id, claim_id)
);

-- Append-only history of every change, for audit.
CREATE TABLE IF NOT EXISTS review_audit (
    id            bigserial   PRIMARY KEY,
    flag_id       text        NOT NULL,
    claim_id      text,                       -- NULL for flag-level changes
    action        text        NOT NULL,       -- STATUS_CHANGE | NOTE | ASSIGN
    old_value     text,
    new_value     text,
    actor         text        NOT NULL,
    at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS review_audit_flag ON review_audit (flag_id, at DESC);

-- Saved feed filters per user or team. Applied by the API; never affect detection.
CREATE TABLE IF NOT EXISTS saved_view (
    id            bigserial   PRIMARY KEY,
    owner         text        NOT NULL,
    name          text        NOT NULL,
    filter_json   jsonb       NOT NULL,       -- e.g. {"severity":["HIGH"],"clients":["C-4411"]}
    shared        boolean     NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (owner, name)
);
