-- Older clients could occupy a slot without ever scheduling a check or renewing it.
DELETE FROM devices WHERE json_array_length(alerts) = 0;
