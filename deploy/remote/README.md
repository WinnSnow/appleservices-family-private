# Deploy to a Linux server

Two pieces land on the host:

1. **anisette-v3** — the service that mints Apple device headers, bound to
   `127.0.0.1:6969` so it is never exposed publicly.
2. **Go tools** — `login`, `trusted-device`, `dashboard`, `familyinspect`,
   `accountsetupcheck`, `anisettecheck` in `/opt/appsvc/bin`.

State lives in `/opt/appsvc/state` with mode `0700`. On Linux this is real
ownership isolation, unlike `0600` on Windows which leaves inherited ACEs.

## One command from Windows

```powershell
cd deploy\remote
.\deploy.ps1 -Server SERVER_IP -User root -Password 'YOUR_PASSWORD'
```

Avoid shell history with a file:

```powershell
'YOUR_PASSWORD' | Set-Content -NoNewline .\pw.txt
.\deploy.ps1 -Server SERVER_IP -User root -PasswordFile .\pw.txt
Remove-Item .\pw.txt
```

Stages can run separately:

```powershell
.\deploy.ps1 -Server SERVER_IP -User root -Password '...' -Mode docker   # anisette only
.\deploy.ps1 -Server SERVER_IP -User root -Password '...' -Mode app      # Go tools only
.\deploy.ps1 -Server SERVER_IP -User root -Password '...' -Mode verify   # re-run checks
```

## One command on the server

If the repository is already there:

```bash
sudo ANISETTE_PORT=6969 bash deploy/remote/setup.sh all
```

Subcommands: `docker`, `app`, `verify`, `all`. The script is idempotent.

## What `setup.sh` does

**`docker`** — installs Docker Engine + compose plugin when missing (distro
packages first, then `get.docker.com`), writes `/opt/anisette/docker-compose.yml`
with a loopback-only port binding, starts the container, then waits up to 180 s
for `/v3/client_info`. The first start downloads Apple's ADI libraries and
self-provisions, which takes about 40 s on a fresh host.

**`app`** — installs the Go toolchain if absent, resolving the current release
from `https://go.dev/dl/?mode=json` instead of pinning a version, then builds
every tool with `CGO_ENABLED=0`. No gcc needed.

**`verify`** — the same four checks as `deploy/anisette/verify.sh`:
`client_info`, an empty `adi_pb` probe that must be *refused*, a WebSocket
`101`, and a full client round-trip that includes real Apple provisioning.

## Networking

The anisette service stays on loopback. Only the app host needs to reach it,
so no inbound firewall rule is required and nothing is exposed to the internet.

If the tools run on a **different** machine, tunnel instead of publishing:

```bash
ssh -N -L 6969:127.0.0.1:6969 root@SERVER_IP
# then on the app host:
./bin/login -dir state/A -twofactor sms -anisette http://127.0.0.1:6969
```

## After deploy

```bash
# 1. Log in each account, one state directory per Apple ID
/opt/appsvc/bin/login -dir /opt/appsvc/state/A -twofactor sms \
    -anisette http://127.0.0.1:6969

# 2. Produce the accepted iCloud checkpoint the family tools require
/opt/appsvc/bin/accountsetupcheck -dir /opt/appsvc/state/A -delegate-only \
    -icloud-checkpoint /opt/appsvc/state/A/icloud-accepted.json

# 3. Read-only family check before touching anything
/opt/appsvc/bin/familyinspect -dir /opt/appsvc/state/A \
    -anisette http://127.0.0.1:6969 -safe-json

# 4. Create the family, then add the second account by PET (no phone needed)
/opt/appsvc/bin/familyinspect -dir /opt/appsvc/state/A \
    -anisette http://127.0.0.1:6969 -create-family
/opt/appsvc/bin/familyinspect -dir /opt/appsvc/state/A \
    -anisette http://127.0.0.1:6969 -add-pool-member-dir /opt/appsvc/state/B
```

`-anisette` replaces the public pool rather than preferring it
(`flow.go:79` → `NewProviderFromState(st, o.servers)`), so device identity
never leaves the host.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker: command not found` after setup | distro has no package and `get.docker.com` was unreachable | check `/tmp/docker-install.log`, install Docker manually, re-run |
| container exits immediately | volume permissions on the ADI lib cache | `docker compose down -v && docker compose up -d` (re-provisions) |
| `client_info` hangs | first-run Apple library download still running | `docker compose logs -f`, wait ~40 s |
| `provisioning_session` returns 404 | reverse proxy not forwarding the path | pass `Upgrade`/`Connection`, see `deploy/anisette/nginx.conf` |
| `-45061 not provisioned` | identifier has no ADI blob yet | expected on a cold identity; the client provisions first |
