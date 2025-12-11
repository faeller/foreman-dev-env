# foreman-dev-env

docker-compose-based dev environment for foreman/katello plugin development.

## quickstart

```bash
# foreman only
./scripts/setup.sh
./scripts/start.sh

# with katello
./scripts/setup.sh -k
./scripts/start-katello.sh
```

http://localhost:3000 (admin / changeme)

## modes

| mode | command | services | ram |
|------|---------|----------|-----|
| foreman | `./scripts/start.sh` | postgres, redis, foreman, worker | ~4gb |
| katello | `./scripts/start-katello.sh` | + candlepin, pulp | ~12gb |
| testhosts | `./scripts/start.sh -t` | + rocky/debian containers | +1gb |

## plugin development

```bash
# symlink your plugin
ln -s /path/to/your/plugin ./foreman-plugins/

# or use the script
./scripts/plugin.sh add ~/my-plugin

# manage plugins
./scripts/plugin.sh              # show status
./scripts/plugin.sh sync         # rescan and update bundler.d
./scripts/plugin.sh install      # sync + bundle install + restart
./scripts/plugin.sh restart      # restart foreman services
```

plugins go in `./foreman-plugins/`. code changes are live (mounted).

## test hosts

containerized hosts for testing foreman management features:

```bash
./scripts/start.sh -t                  # start with test hosts
./scripts/testhosts.sh status          # show status
./scripts/testhosts.sh ssh 1           # shell into testhost1
./scripts/testhosts.sh ssh debian      # shell into debian host
./scripts/testhosts.sh register        # register hosts with foreman
```

| host | os | ssh port |
|------|----|----------|
| testhost1 | Rocky Linux 9 | 2201 |
| testhost2 | Rocky Linux 9 | 2202 |
| testhost3 | Rocky Linux 9 | 2203 |
| testhost-debian | Debian 12 | 2204 |

credentials: root/changeme, foreman/foreman

hosts auto-register with foreman on startup and report facts every 2 minutes.

## common tasks

```bash
./scripts/console.sh      # rails console
./scripts/logs.sh         # foreman logs
./scripts/logs.sh all     # all service logs
./scripts/status.sh       # environment status
./scripts/stop.sh         # stop everything
```

## services

```
foreman only:
  db, redis, foreman, orchestrator, worker

with katello (--profile katello):
  + candlepin, pulp-api, pulp-content, pulp-worker

with testhosts (--profile testhosts):
  + testhost1, testhost2, testhost3, testhost-debian
```

## ports

| port | service |
|------|---------|
| 3000 | foreman web UI |
| 8080 | candlepin (katello) |
| 24817 | pulp API (katello) |
| 2201-2204 | test host SSH |

## reset

```bash
./scripts/stop.sh
docker compose down -v    # removes all data
./scripts/setup.sh
```

## requirements

- docker with compose plugin
- ~4gb ram (foreman) / ~12gb (katello)
