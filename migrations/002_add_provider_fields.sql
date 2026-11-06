ALTER TABLE transfers ADD COLUMN provider_reference TEXT;
ALTER TABLE transfers ADD COLUMN client_ip TEXT;
CREATE INDEX transfers_status_idx ON transfers (status);
