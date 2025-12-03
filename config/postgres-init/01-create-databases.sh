#!/bin/bash
# create additional databases for katello services (idempotent)
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE candlepin' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'candlepin')\gexec
    SELECT 'CREATE DATABASE pulp' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'pulp')\gexec
    GRANT ALL PRIVILEGES ON DATABASE candlepin TO foreman;
    GRANT ALL PRIVILEGES ON DATABASE pulp TO foreman;
EOSQL
