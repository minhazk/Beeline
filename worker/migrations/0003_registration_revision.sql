-- A cron snapshot may outlive an alert edit or a new registration for the same device.
-- Existing registrations acquire a fresh revision on their next write.
ALTER TABLE devices ADD COLUMN revision TEXT NOT NULL DEFAULT '';

-- Existing phones keep their device-secret ownership. Each new invitation can admit
-- one device at a time; deleting or retiring its device frees the invitation.
ALTER TABLE devices ADD COLUMN enrollment_hash TEXT;
CREATE UNIQUE INDEX devices_enrollment_hash ON devices(enrollment_hash);

DELETE FROM meta WHERE key = 'apns_jwt' AND value NOT LIKE 'v1:%';
