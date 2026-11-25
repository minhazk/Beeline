-- Rows from before each install had its own secret have no owner: no phone can change, test or
-- remove them, yet their push token and journeys stayed and were checked. Their phones register
-- again, with a secret, the next time the app is opened.
DELETE FROM devices WHERE secret_hash IS NULL;
