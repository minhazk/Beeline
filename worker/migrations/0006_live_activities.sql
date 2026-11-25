-- Next-train Live Activities the server keeps up to date (activities.ts): each one's own push
-- token, what it follows and until when, and what was last sent, so only changes are pushed.
-- Owned like a phone's registration: by the install's secret, and counted per invitation.
CREATE TABLE activities (
  token TEXT PRIMARY KEY,
  environment TEXT NOT NULL CHECK (environment IN ('sandbox', 'production')),
  follow TEXT NOT NULL,
  ends_at INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL,
  secret_hash TEXT NOT NULL,
  enrollment_hash TEXT NOT NULL
);
CREATE INDEX activities_enrollment ON activities(enrollment_hash);

-- A phone's push-to-start token, for saved lines that start a Live Activity at their travel
-- times, and which of those times it has been started for already.
ALTER TABLE devices ADD COLUMN start_token TEXT;
ALTER TABLE devices ADD COLUMN started TEXT NOT NULL DEFAULT '{}';
