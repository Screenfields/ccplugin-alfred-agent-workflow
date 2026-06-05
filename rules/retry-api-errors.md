When any API call fails with a transient error (rate limit, 5xx, timeout), retry up to 3 times with brief backoff before surfacing the failure.
