ALTER TABLE transfers ADD COLUMN amount_minor BIGINT;
UPDATE transfers SET amount_minor = (amount * 100)::BIGINT;
ALTER TABLE transfers ALTER COLUMN amount_minor SET NOT NULL;
ALTER TABLE transfers DROP COLUMN amount;
