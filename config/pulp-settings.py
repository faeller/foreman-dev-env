# pulp 3 settings for katello integration
CONTENT_ORIGIN = "http://localhost:24816"
ANSIBLE_API_HOSTNAME = "http://localhost:24817"
ANSIBLE_CONTENT_HOSTNAME = "http://localhost:24816/pulp/content"
TOKEN_AUTH_DISABLED = True
DB_ENCRYPTION_KEY = "/etc/pulp/certs/database_fields.symmetric.key"

# redis cache (configured via env vars, but status check needs this)
import os
REDIS_HOST = os.environ.get("PULP_REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("PULP_REDIS_PORT", 6379))
CACHE_ENABLED = True
