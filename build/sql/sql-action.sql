-- "Mark action taken" from the dashboard: who did what, recorded on the alert log.
ALTER TABLE alert_log ADD COLUMN IF NOT EXISTS action_note  TEXT;
ALTER TABLE alert_log ADD COLUMN IF NOT EXISTS performed_by TEXT;
