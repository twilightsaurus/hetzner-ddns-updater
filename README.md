# Hetzner DDNS Firewall Updater

Updates a Hetzner Cloud Firewall’s **inbound TCP** rules to allow the current IP of a DDNS hostname. Intended to run in a container via `crond`.

## How it works

- Resolves `DDNS_HOSTNAME` to an IP (prefers IPv4, falls back to IPv6)
- Converts it to a CIDR (`/32` for IPv4, `/128` for IPv6)
- Fetches your firewall rules and **replaces** `source_ips` for matching rules
- Calls Hetzner Cloud API `set_rules` action and (by default) waits for completion
- Persists the last applied CIDR in `/state/ip.txt` to avoid unnecessary updates

## Requirements

- A Hetzner Cloud Firewall that already contains inbound TCP rules for the ports you want to manage
- A DNS name that resolves to your current public IP (DDNS)

## Configuration

### Required environment variables

- **`HETZNER_API_TOKEN`**: Hetzner Cloud API token (with permissions to read/update firewalls)
- **`FIREWALL_ID`**: numeric firewall ID
- **`DDNS_HOSTNAME`**: hostname to resolve (e.g. `myhome.example.com`)

### Optional environment variables

- **`CRON_INTERVAL`**: cron schedule (default: `*/5 * * * *`)
- **`TCP_PORTS`**: space-separated ports to update (default: `5432 6380`)
- **`DNS_SERVER`**: optional DNS server for lookups (e.g. `1.1.1.1`)
- **`WAIT_FOR_ACTION`**: set to `0` to not poll the async Hetzner action (default: `1`)
- **`ACTION_TIMEOUT_SECONDS`**: max seconds to wait for the action (default: `60`)
- **`ACTION_POLL_SECONDS`**: poll interval seconds (default: `2`)

## Run with Docker

Build:

```bash
docker build -t hetzner-ddns-updater .
```

Run (recommended: mount `/state` so it survives restarts):

```bash
docker run -d --name hetzner-ddns-updater \
  -e HETZNER_API_TOKEN='***' \
  -e FIREWALL_ID='123456' \
  -e DDNS_HOSTNAME='myhome.example.com' \
  -e TCP_PORTS='5432 6380' \
  -e CRON_INTERVAL='*/5 * * * *' \
  -v hetzner-ddns-updater-state:/state \
  --restart unless-stopped \
  hetzner-ddns-updater
```

Logs:

```bash
docker logs -f hetzner-ddns-updater
```

## Local test (with a `.env` file)

If you have a local `.env` containing the required variables, you can run a one-shot update like this:

```bash
cd /home/tai/benbis/projects/utilities/hetzner-ddns-updater
docker build -t hetzner-ddns-updater .
docker rm -f hetzner-ddns-updater-test 2>/dev/null || true
docker run -d --name hetzner-ddns-updater-test --env-file ./.env -v "$(pwd)/state:/state" hetzner-ddns-updater
docker exec -it hetzner-ddns-updater-test /run-update.sh
```

Note: the `./state` folder is created on your **host** by Docker because of the bind mount (`-v "$(pwd)/state:/state"`). Inside the container it appears as `/state`.

## Deploy on Coolify

High-level: deploy this repo as a Dockerfile-based app, set the env vars as secrets, and mount persistent storage to `/state`.

1. **Create a new Resource**

- Create a new **Application** from your Git repository.
- Build method: **Dockerfile** (uses `./Dockerfile`).

2. **Set environment variables (as secrets)**

- `HETZNER_API_TOKEN`
- `FIREWALL_ID`
- `DDNS_HOSTNAME`
- (optional) `TCP_PORTS`, `CRON_INTERVAL`, `DNS_SERVER`

3. **Add persistent storage**

- Add a **volume** and mount it to **`/state`** inside the container.
  - This keeps `/state/ip.txt` across restarts so the updater stays idempotent.

4. **Networking**

- This service does not expose HTTP ports. In Coolify, you typically don’t need to publish any ports or attach a domain.

5. **Deploy**

- Deploy the application and watch the logs.

6. **Validate the first run**

- Check logs for either “IP unchanged …” or “Firewall updated …”.
- If you want to force a one-shot run immediately, use Coolify’s container terminal/exec and run:

```bash
/run-update.sh
```

## Notes / gotchas

- **Replace semantics**: the script **overwrites** `source_ips` with exactly one CIDR (the resolved DDNS IP) for matching rules.
- **Rules must exist**: if there are **no** matching inbound TCP rules for `TCP_PORTS`, the script exits non-zero and does not update state.
- **Async actions**: Hetzner `set_rules` returns an **Action**; by default the script polls until it succeeds before writing state.
