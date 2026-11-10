# Self-hosted anisette-v3

The login flow gets its Apple device headers (`X-Apple-I-MD`, `X-Apple-I-MD-M`,
`X-Apple-I-MD-RINFO`) from an anisette service. By default it uses the public
pool at `https://servers.sidestore.io/servers.json` (`anisette/server_list.go:14`),
which means every login hands your device identity to a third party.

This directory runs that service yourself, so the identity stays on hardware
you control.

## Why this server and not something else

`docs/protocol-audit.md:18` already points at
[Dadoum/anisette-v3-server](https://github.com/Dadoum/anisette-v3-server) and
contributed a fix upstream (PR #60). The wire contract matches field by field:

| This repo expects | Location | anisette-v3-server returns | Source |
|---|---|---|---|
| `GET /v3/client_info` → `{client_info, user_agent}` | `anisette/client.go:29-42` | `{"client_info":…,"user_agent":"akd/1.0 CFNetwork/808.1.4"}` | `source/app.d` |
| `POST /v3/get_headers` `{identifier, adi_pb}` → `{result:"Headers",…}` | `anisette/client.go:46-79` | `{"result":"Headers","X-Apple-I-MD":…,"X-Apple-I-MD-M":…,"X-Apple-I-MD-RINFO":"17106176"}` | `source/app.d` |
| `RINFO` fallback `17106176` | `anisette/client.go:82` | literal `17106176` | `source/app.d` |
| `GET /v3/provisioning_session` WebSocket, `GiveIdentifier` → `GiveStartProvisioningData` → `GiveEndProvisioningData` → `ProvisioningSuccess` | `anisette/provision.go:22-79` | same message names | `source/app.d` |

`tools/anisettecheck` pins the two HTTP responses against this repo's own
client, so a contract drift fails a test instead of a login.

## Deploy

```bash
cd deploy/anisette
docker compose up -d
docker compose logs -f --tail 20
```

The container publishes on `127.0.0.1:6969` only. Published platforms are
`linux/386`, `linux/amd64`, `linux/arm64/v8` (upstream README).

## Point the tools at it

`-anisette` replaces the public pool entirely (`flow.go:79` →
`NewProviderFromState(st, o.servers)`); it is not a preferred-first list.

```bash
./bin/login -dir state/A -twofactor sms -anisette http://127.0.0.1:6969
./bin/familyinspect -dir state/A -anisette http://127.0.0.1:6969 -safe-json
```

Remote anisette host (TLS in front, WebSocket upgrade required):

```bash
./bin/login -dir state/A -twofactor sms -anisette https://anisette.example.com
```

The client rewrites `https://` to `wss://` for the provisioning session
(`anisette/provision.go:21-22`), so the reverse proxy must pass
`Upgrade`/`Connection` headers — `nginx.conf` in this directory does.

## Verify

```bash
CGO_ENABLED=0 go build -o bin/anisettecheck ./tools/anisettecheck
chmod +x deploy/anisette/verify.sh
./deploy/anisette/verify.sh http://127.0.0.1:6969 ./bin/anisettecheck
```

Expected: `client_info OK`, an error document for the empty `adi_pb` probe,
a complete header set from the client round-trip, and `101 Switching Protocols`.

## Operational notes

- **No Apple egress needed on this host.** The client does Apple's
  `midStartProvisioning`/`midFinishProvisioning` handshake itself
  (`anisette/provision.go:53-68`, `anisette/albert.go:113`) and sends only
  `spim`/`ptm`/`tk` over the WebSocket. This container just runs the ADI math.
- **Keep it loopback.** It mints trusted-device headers for any identifier it
  is asked about; whoever reaches it can impersonate your device.
- **One identity per account directory.** The provisioning blob lives in that
  directory's state (see `anisette/state.go`), not in the service.
- **Rate limits still apply.** The service is not a throttle bypass; Apple
  still sees the login attempts from your IP.
