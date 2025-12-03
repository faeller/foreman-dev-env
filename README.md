# foreman-dev-env

docker-compose-based dev environment for foreman/katello (plugin) development.

## quickstart

```bash
# foreman only
./scripts/setup.sh
./scripts/start.sh

# with katello
./scripts/setup.sh --katello
./scripts/start.sh --katello
```

http://localhost:3000 (admin / changeme)

## modes

| mode | command | services | ram |
|------|---------|----------|-----|
| foreman | `./start.sh` | postgres, redis, foreman, worker | ~4gb |
| katello | `./start.sh -k` | + candlepin, pulp | ~12gb |

## plugin dev

```bash
./scripts/plugin.sh                   # show status
./scripts/plugin.sh sync              # scan & update bundler.d
./scripts/plugin.sh add ~/my-plugin   # symlink plugin
./scripts/plugin.sh rm my_plugin      # remove plugin
```

plugins dir: `../foreman-plugins/` (override with `PLUGINS_PATH` in `.env`)

after adding a plugin, restart foreman to load it. code changes are live (mounted).

## test hosts

docker containers or libvirt vms for provisioning tests:

```bash
# docker (--profile testhosts)
./scripts/start.sh -t                       # ssh on ports 2201-2203 (root:changeme)

# libvirt vms
./scripts/provision-host.sh testhost1       # cloud-init vm
./scripts/provision-host.sh -p testhost2    # pxe-bootable
./scripts/list-hosts.sh
./scripts/destroy-host.sh testhost1
```

## common tasks

```bash
./scripts/ssh.sh          # shell
./scripts/console.sh      # rails console
./scripts/logs.sh         # foreman logs
./scripts/logs.sh all     # all logs
./scripts/status.sh       # status
```

## services

```
$ docker compose ps
NAME           STATUS         PORTS
db             Up (healthy)   5432/tcp
redis          Up (healthy)   6379/tcp
foreman        Up             0.0.0.0:3000->3000/tcp
orchestrator   Up
worker         Up

# with --profile katello:
candlepin      Up             0.0.0.0:8080->8080/tcp
pulp-api       Up             0.0.0.0:24817->24817/tcp
pulp-content   Up             0.0.0.0:24816->24816/tcp
pulp-worker    Up

# with --profile testhosts:
testhost1      Up             0.0.0.0:2201->22/tcp
testhost2      Up             0.0.0.0:2202->22/tcp
testhost3      Up             0.0.0.0:2203->22/tcp
```

## reset

```bash
./scripts/stop.sh
docker compose down -v
./scripts/setup.sh
```

## requirements

- docker w/ compose
- libvirt/kvm (optional, for test vms)

## roadmap

- [ ] smart-proxy container (dhcp/tftp/dns)
- [ ] full pxe provisioning with libvirt vms
- [ ] discovery image integration
