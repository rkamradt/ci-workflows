-- Bad migration fixture — used by test-ai-gate.yml to verify the gate blocks.
-- This file intentionally contains a blocking rule violation.

BEGIN;

ALTER TABLE users ADD COLUMN last_seen TIMESTAMP;

DROP TABLE legacy_sessions;   -- AI-Gate: SQL_DESTRUCTIVE

COMMIT;
