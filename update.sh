#!/bin/sh
set -eu

if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

# Create cron job
CRON_FILE="/etc/crontabs/root"
: "${CRON_INTERVAL:=*/5 * * * *}"
if printf %s "$CRON_INTERVAL" | grep -q '[[:cntrl:]]'; then
  echo "Invalid CRON_INTERVAL (contains control chars)"
  exit 1
fi
echo "$CRON_INTERVAL /run-update.sh" > "$CRON_FILE"

# Create the actual updater script
cat << 'EOF' > /run-update.sh
#!/bin/sh
set -eu

if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

umask 077

LOCK_DIR="/tmp/run-update.lock"
SET_RULES_RESP_FILE=""

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [ -n "${SET_RULES_RESP_FILE:-}" ]; then
    rm -f "$SET_RULES_RESP_FILE" 2>/dev/null || true
  fi
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another run is in progress; exiting"
  exit 0
fi
trap 'cleanup' EXIT

if [ -z "$HETZNER_API_TOKEN" ] || [ -z "$FIREWALL_ID" ] || [ -z "$DDNS_HOSTNAME" ]; then
  echo "Missing required env vars: HETZNER_API_TOKEN, FIREWALL_ID, DDNS_HOSTNAME"
  exit 1
fi

# Optional env vars:
# - DNS_SERVER: e.g. 1.1.1.1 (defaults to container resolver if unset)
# - TCP_PORTS: space-separated ports to update (default: "5432 6380")
# - WAIT_FOR_ACTION: "1" (default) waits for set_rules action to finish
# - ACTION_TIMEOUT_SECONDS: max seconds to wait (default: 60)
# - ACTION_POLL_SECONDS: poll interval seconds (default: 2)
DNS_SERVER="${DNS_SERVER:-}"
TCP_PORTS="${TCP_PORTS:-5432 6380}"
WAIT_FOR_ACTION="${WAIT_FOR_ACTION:-1}"
ACTION_TIMEOUT_SECONDS="${ACTION_TIMEOUT_SECONDS:-60}"
ACTION_POLL_SECONDS="${ACTION_POLL_SECONDS:-2}"

# Resolve current IP from DDNS
if [ -n "$DNS_SERVER" ]; then
  DIG_ARGS="@${DNS_SERVER}"
else
  DIG_ARGS=""
fi

IPV4="$(dig ${DIG_ARGS} +short A "$DDNS_HOSTNAME" | awk 'NF{print; exit}')"
IPV6="$(dig ${DIG_ARGS} +short AAAA "$DDNS_HOSTNAME" | awk 'NF{print; exit}')"

if [ -n "$IPV4" ]; then
  IP="$IPV4"
  NEW_IP="$IP/32"
elif [ -n "$IPV6" ]; then
  IP="$IPV6"
  NEW_IP="$IP/128"
else
  echo "Failed to resolve hostname $DDNS_HOSTNAME"
  exit 0
fi

STATE_DIR="/state"
STATE_FILE="$STATE_DIR/ip.txt"
mkdir -p "$STATE_DIR"

if [ -f "$STATE_FILE" ]; then
  OLD_IP=$(cat "$STATE_FILE")
else
  OLD_IP=""
fi

if [ "$OLD_IP" = "$NEW_IP" ]; then
  if [ "$TCP_PORTS" = "${TCP_PORTS% *}" ]; then
    echo "IP unchanged for port $TCP_PORTS: $NEW_IP"
  else
    echo "IP unchanged for ports $TCP_PORTS: $NEW_IP"
  fi
  exit 0
fi

if [ "$TCP_PORTS" = "${TCP_PORTS% *}" ]; then
  echo "IP changed for port $TCP_PORTS: $OLD_IP -> $NEW_IP"
else
  echo "IP changed for ports $TCP_PORTS: $OLD_IP -> $NEW_IP"
fi

# Fetch current firewall configuration
FIREWALL_JSON="$(curl -fsS \
  --connect-timeout 5 \
  --max-time 20 \
  --retry 3 \
  --retry-delay 2 \
  -H "Authorization: Bearer ${HETZNER_API_TOKEN}" \
  "https://api.hetzner.cloud/v1/firewalls/${FIREWALL_ID}")"

if [ -z "$FIREWALL_JSON" ]; then
  echo "Failed to fetch firewall $FIREWALL_ID"
  exit 1
fi

if ! echo "$FIREWALL_JSON" | jq -e '.firewall.rules | type == "array"' >/dev/null 2>&1; then
  echo "Unexpected firewall API response (missing .firewall.rules array)"
  exit 1
fi

# Update only the inbound TCP rules for configured ports
UPDATE_PLAN="$(echo "$FIREWALL_JSON" | jq -c --arg ip "$NEW_IP" --arg ports "$TCP_PORTS" '
  def port_set($s): ($s | split(" ") | map(select(length>0)) | unique);
  ($ports | port_set(.)) as $port_list
  | (.firewall.rules) as $rules
  | ($rules | map(
      . as $r
      | if $r.direction == "in"
         and $r.protocol == "tcp"
         and ($port_list | index($r.port))
      then 1 else 0 end
    ) | add) as $matched
  | ($rules | map(
      . as $r
      | if $r.direction == "in"
         and $r.protocol == "tcp"
         and ($port_list | index($r.port))
         and ($r.source_ips != [$ip])
      then 1 else 0 end
    ) | add) as $changed
  | {
      rules: (
        $rules
        | map(
            . as $r
            | if $r.direction == "in"
               and $r.protocol == "tcp"
               and ($port_list | index($r.port))
            then
              $r | .source_ips = [$ip]
            else
              $r
            end
          )
      ),
      matched: ($matched // 0),
      changed: ($changed // 0)
    }
')" 

MATCHED="$(echo "$UPDATE_PLAN" | jq -r '.matched')"
CHANGED="$(echo "$UPDATE_PLAN" | jq -r '.changed')"

if [ "$MATCHED" -eq 0 ]; then
  echo "No matching inbound tcp rules found for ports: $TCP_PORTS"
  exit 1
fi

if [ "$CHANGED" -eq 0 ]; then
  echo "Firewall already allows $NEW_IP for ports $TCP_PORTS; updating state"
  echo "$NEW_IP" > "$STATE_FILE"
  exit 0
fi

UPDATED_RULES="$(echo "$UPDATE_PLAN" | jq -c '.rules')"

# Push updated rules back to Hetzner (returns an async Action)
PAYLOAD="$(jq -cn --argjson rules "$UPDATED_RULES" '{rules: $rules}')"

SET_RULES_RESP_FILE="$(mktemp)"

HTTP_CODE="$(curl -sS -X POST \
  --connect-timeout 5 \
  --max-time 20 \
  --retry 3 \
  --retry-delay 2 \
  -H "Authorization: Bearer ${HETZNER_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  -o "$SET_RULES_RESP_FILE" \
  -w '%{http_code}' \
  "https://api.hetzner.cloud/v1/firewalls/${FIREWALL_ID}/actions/set_rules")"

SET_RULES_RESPONSE="$(cat "$SET_RULES_RESP_FILE")"

case "$HTTP_CODE" in
  2??) : ;;
  *)
    echo "Hetzner set_rules failed (HTTP $HTTP_CODE)"
    if [ -n "$SET_RULES_RESPONSE" ]; then
      echo "Response body:"
      echo "$SET_RULES_RESPONSE"
    fi
    exit 1
    ;;
esac

if ! echo "$SET_RULES_RESPONSE" | jq -e . >/dev/null 2>&1; then
  echo "Hetzner set_rules returned non-JSON (HTTP $HTTP_CODE)"
  if [ -n "$SET_RULES_RESPONSE" ]; then
    echo "Response body:"
    echo "$SET_RULES_RESPONSE"
  fi
  exit 1
fi

ACTION_ID="$(echo "$SET_RULES_RESPONSE" | jq -r '(.action.id // .actions[0].id // empty)')"
ACTION_STATUS="$(echo "$SET_RULES_RESPONSE" | jq -r '(.action.status // .actions[0].status // empty)')"

if [ -z "$ACTION_ID" ]; then
  echo "Unexpected response from set_rules (missing action id) (HTTP $HTTP_CODE)"
  echo "$SET_RULES_RESPONSE" | jq -c . 2>/dev/null || true
  exit 1
fi

if [ "$WAIT_FOR_ACTION" != "0" ] && [ "$ACTION_STATUS" != "success" ]; then
  START_TS="$(date +%s)"
  while :; do
    NOW_TS="$(date +%s)"
    ELAPSED="$((NOW_TS - START_TS))"
    if [ "$ELAPSED" -ge "$ACTION_TIMEOUT_SECONDS" ]; then
      echo "Timed out waiting for action $ACTION_ID (last status: $ACTION_STATUS)"
      exit 1
    fi

    ACTION_JSON="$(curl -fsS \
      --connect-timeout 5 \
      --max-time 20 \
      --retry 3 \
      --retry-delay 2 \
      -H "Authorization: Bearer ${HETZNER_API_TOKEN}" \
      "https://api.hetzner.cloud/v1/firewalls/${FIREWALL_ID}/actions/${ACTION_ID}")"

    ACTION_STATUS="$(echo "$ACTION_JSON" | jq -r '.action.status // empty')"
    if [ "$ACTION_STATUS" = "success" ]; then
      break
    fi
    if [ "$ACTION_STATUS" = "error" ]; then
      ACTION_ERROR_CODE="$(echo "$ACTION_JSON" | jq -r '.action.error.code // empty')"
      ACTION_ERROR_MSG="$(echo "$ACTION_JSON" | jq -r '.action.error.message // empty')"
      echo "Hetzner action failed: ${ACTION_ERROR_CODE:-action_failed} ${ACTION_ERROR_MSG:-}"
      exit 1
    fi

    sleep "$ACTION_POLL_SECONDS"
  done
fi

echo "$NEW_IP" > "$STATE_FILE"
echo "Firewall updated for ports $TCP_PORTS with $NEW_IP"
EOF

chmod +x /run-update.sh

# Start cron in foreground
crond -f -l 2
