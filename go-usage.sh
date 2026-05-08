#!/usr/bin/env bash

# OpenCode Go Usage CLI Script
# Extracts your login cookie from your browser and fetches usage data.

set -e

CONFIG_DIR="${HOME}/.config/opencode/go-usage-bash"
CONFIG_FILE="${CONFIG_DIR}/config.json"
API_URL="https://opencode.ai/_server"
MONTH_NAMES=("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

TMPFILES=()
cleanup() {
    for f in "${TMPFILES[@]}"; do rm -f "$f"; done
}
trap cleanup EXIT

die() {
    echo "${RED}Error:${RESET} $1" >&2
    exit 1
}

require_config() {
    [ -f "$CONFIG_FILE" ] || die "Configuration not found. Run '$0 login' first."
}

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is required. Please install it."
}

ensure_config_dir() {
    [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"
}

login() {
    ensure_config_dir

    echo "${BOLD}Login Setup${RESET}"
    echo ""
    echo "Steps to get your auth cookie:"
    echo "  1. Log in to your OpenCode account in the browser"
    echo "  2. Open DevTools (F12) -> Application -> Cookies -> https://opencode.ai"
    echo "  3. Find the cookie named 'auth'"
    echo "  4. Copy its full value (starts with 'Fe26.2**')"
    echo ""
    read -rp "Paste your auth cookie: " AUTH_COOKIE
    [ -n "$AUTH_COOKIE" ] || die "Auth cookie cannot be empty."
    echo "${GREEN}Auth cookie saved.${RESET}"
    echo ""

    read -rp "Workspace ID [wrk_01KDSXX2YK0SSF30AKBTQGWQM9]: " WORKSPACE_ID
    WORKSPACE_ID=${WORKSPACE_ID:-wrk_01KDSXX2YK0SSF30AKBTQGWQM9}

    read -rp "Server ID [15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205]: " SERVER_ID
    SERVER_ID=${SERVER_ID:-15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205}

    read -rp "Function ID [31]: " FUNCTION_ID
    FUNCTION_ID=${FUNCTION_ID:-31}

    echo ""
    echo "What day of the month does your billing cycle start?"
    echo "${DIM}(e.g., if you subscribed on 20-Apr, enter 20)${RESET}"
    read -rp "Billing cycle day [1]: " SUB_DAY
    SUB_DAY=${SUB_DAY:-1}
    [[ "$SUB_DAY" =~ ^[0-9]+$ ]] && [ "$SUB_DAY" -ge 1 ] && [ "$SUB_DAY" -le 31 ] \
        || die "Invalid day. Must be a number between 1 and 31."

    cat <<EOF > "$CONFIG_FILE"
{
  "authCookie": "$AUTH_COOKIE",
  "workspaceId": "$WORKSPACE_ID",
  "serverId": "$SERVER_ID",
  "functionId": $FUNCTION_ID,
  "subDay": $SUB_DAY
}
EOF
    echo "${GREEN}Configuration saved to ${CONFIG_FILE}${RESET}"
}

set_sub_day() {
    require_config
    require_cmd jq

    CURRENT_SUB_DAY=$(jq -r '.subDay // 1' "$CONFIG_FILE")
    echo "Current billing cycle day: ${BOLD}${CURRENT_SUB_DAY}${RESET}"
    echo ""
    echo "What day of the month does your billing cycle start?"
    echo "${DIM}(e.g., if you subscribed on 20-Apr, enter 20)${RESET}"
    read -rp "Billing cycle day [1]: " SUB_DAY
    SUB_DAY=${SUB_DAY:-1}
    [[ "$SUB_DAY" =~ ^[0-9]+$ ]] && [ "$SUB_DAY" -ge 1 ] && [ "$SUB_DAY" -le 31 ] \
        || die "Invalid day. Must be a number between 1 and 31."

    TMP_FILE=$(mktemp)
    TMPFILES+=("$TMP_FILE")
    jq ".subDay = $SUB_DAY" "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"
    echo "${GREEN}Billing cycle day updated to ${SUB_DAY}${RESET}"
}

fetch_and_report() {
    require_config
    require_cmd jq
    require_cmd curl
    require_cmd node

    AUTH_COOKIE=$(jq -r '.authCookie' "$CONFIG_FILE")
    WORKSPACE_ID=$(jq -r '.workspaceId' "$CONFIG_FILE")
    SERVER_ID=$(jq -r '.serverId' "$CONFIG_FILE")
    FUNCTION_ID=$(jq -r '.functionId' "$CONFIG_FILE")
    SUB_DAY=$(jq -r '.subDay // 1' "$CONFIG_FILE")

    CURRENT_DAY=$(date +%-d)
    CURRENT_MONTH=$(date +%-m)
    CURRENT_YEAR=$(date +%Y)

    # Determine which calendar months fall in the current billing cycle
    if [ "$CURRENT_DAY" -lt "$SUB_DAY" ]; then
        PREV_MONTH=$((CURRENT_MONTH - 1))
        if [ "$PREV_MONTH" -eq 0 ]; then
            PREV_MONTH=12
            PREV_YEAR=$((CURRENT_YEAR - 1))
        else
            PREV_YEAR=$CURRENT_YEAR
        fi
        MONTHS_TO_FETCH="$PREV_YEAR:$PREV_MONTH $CURRENT_YEAR:$CURRENT_MONTH"
        BILLING_START="$SUB_DAY ${MONTH_NAMES[$((PREV_MONTH - 1))]} $PREV_YEAR"
        BILLING_END="$SUB_DAY ${MONTH_NAMES[$((CURRENT_MONTH - 1))]} $CURRENT_YEAR"
    else
        NEXT_MONTH=$((CURRENT_MONTH + 1))
        if [ "$NEXT_MONTH" -eq 13 ]; then
            NEXT_MONTH=1
            NEXT_YEAR=$((CURRENT_YEAR + 1))
        else
            NEXT_YEAR=$CURRENT_YEAR
        fi
        MONTHS_TO_FETCH="$CURRENT_YEAR:$CURRENT_MONTH"
        BILLING_START="$SUB_DAY ${MONTH_NAMES[$((CURRENT_MONTH - 1))]} $CURRENT_YEAR"
        BILLING_END="$SUB_DAY ${MONTH_NAMES[$((NEXT_MONTH - 1))]} $NEXT_YEAR"
    fi
    BILLING_PERIOD="$BILLING_START – $BILLING_END"

    RESPONSE_FILES=()
    echo "${DIM}Fetching usage data...${RESET}"

    REQUEST_FILE=$(mktemp /tmp/go-usage-request-XXXXXX)
    TMPFILES+=("$REQUEST_FILE")

    for YM in $MONTHS_TO_FETCH; do
        YEAR="${YM%%:*}"
        MONTH="${YM##*:}"
        JS_MONTH=$((MONTH - 1))

        cat <<EOF > "$REQUEST_FILE"
{
  "t": {
    "t": 9,
    "i": 0,
    "l": 4,
    "o": 0,
    "a": [
      { "t": 1, "s": "$WORKSPACE_ID" },
      { "t": 0, "s": $YEAR },
      { "t": 0, "s": $JS_MONTH },
      { "t": 1, "s": "UTC" }
    ]
  },
  "f": $FUNCTION_ID,
  "m": []
}
EOF

        HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
          -H "accept: */*" \
          -H "accept-language: en-GB,en;q=0.9" \
          -H "content-type: application/json" \
          -H "cookie: oc_locale=en; auth=$AUTH_COOKIE" \
          -H "origin: https://opencode.ai" \
          -H "referer: https://opencode.ai/workspace/$WORKSPACE_ID/usage" \
          -H "x-server-id: $SERVER_ID" \
          -H "x-server-instance: server-fn:0" \
          -d @"$REQUEST_FILE")

        HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
        HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

        if [ "$HTTP_STATUS" -ne 200 ]; then
            echo "${RED}Failed to fetch data. HTTP $HTTP_STATUS${RESET}"
            echo "$HTTP_BODY"
            exit 1
        fi

        RESPONSE_FILE=$(mktemp /tmp/go-usage-response-XXXXXX)
        TMPFILES+=("$RESPONSE_FILE")
        echo "$HTTP_BODY" > "$RESPONSE_FILE"
        RESPONSE_FILES+=("$RESPONSE_FILE")
    done

    PARSER_FILE=$(mktemp /tmp/go-usage-parser-XXXXXX.js)
    TMPFILES+=("$PARSER_FILE")

    cat << 'PARSEREOF' > "$PARSER_FILE"
const fs = require('fs');

function parseJsResponse(text) {
  const jsCode = text.replace(/^;0x[0-9a-fA-F]+;/, "");
  const fixedCode = jsCode.replace(
    /\(\$R\["server-fn:0"\]\)\)$/,
    '(self.$R["server-fn:0"]))'
  );
  const self = {};
  let $R = [];
  self.$R = $R;
  return eval(fixedCode);
}

function unwrapValue(data) {
  if (Array.isArray(data) && data.length === 1) return data[0];
  if (data && typeof data === "object") {
    if ("value" in data) return data.value;
    if ("_$value" in data) return data._$value;
  }
  return data;
}

function extractData(text) {
  let parsed;
  if (text.includes('text/javascript') || text.startsWith(';0x')) {
    parsed = parseJsResponse(text);
  } else {
    parsed = JSON.parse(text);
  }
  const unwrapped = unwrapValue(parsed);
  return {
    usage: Array.isArray(unwrapped?.usage) ? unwrapped.usage : (Array.isArray(unwrapped) ? unwrapped : []),
    keys: Array.isArray(unwrapped?.keys) ? unwrapped.keys : []
  };
}

try {
  const billingPeriod = process.env.BILLING_PERIOD || "Current Period";
  const billingEnd = process.env.BILLING_END || "";
  const files = process.argv.slice(2);
  if (files.length === 0) {
    console.error("No response files provided");
    process.exit(1);
  }

  const allUsage = [];
  const allKeys = [];
  const seenKeys = new Set();

  for (const file of files) {
    const text = fs.readFileSync(file, 'utf-8');
    const data = extractData(text);
    allUsage.push(...data.usage);
    for (const k of data.keys) {
      if (!seenKeys.has(k.id)) {
        seenKeys.add(k.id);
        allKeys.push(k);
      }
    }
  }

  const keyCosts = new Map();
  allKeys.forEach(k => {
    if (!k.deleted) {
      keyCosts.set(k.id, { cost: 0, name: k.displayName || "Unknown Key", deleted: false });
    }
  });

  allUsage.forEach(row => {
    if (row.plan !== "sub" && row.plan !== "lite") return;
    const keyId = row.keyId || "unknown";
    const cost = row.totalCost || 0;
    if (!keyCosts.has(keyId)) {
      const keyInfo = allKeys.find(k => k.id === keyId);
      keyCosts.set(keyId, {
        cost: 0,
        name: keyInfo?.displayName || "Unknown Key",
        deleted: keyInfo?.deleted || false
      });
    }
    keyCosts.get(keyId).cost += cost;
  });

  let totalCost = 0;
  const results = [];
  keyCosts.forEach((info) => {
    if (!info.deleted) {
      const costDollars = info.cost / 100000000;
      totalCost += costDollars;
      results.push({ name: info.name, cost: costDollars });
    }
  });

  results.sort((a, b) => b.cost - a.cost);

  const R   = '\x1b[0m';
  const B   = '\x1b[1m';
  const DM  = '\x1b[2m';
  const GR  = '\x1b[32m';
  const YL  = '\x1b[33m';
  const RD  = '\x1b[31m';
  const CY  = '\x1b[36m';
  const WH  = '\x1b[37m';

  const allowance = 60.0;
  const remaining = allowance - totalCost;
  const pctUsed = (totalCost / allowance) * 100;

  const W = 52;
  const hr = '─'.repeat(W);

  const barW = W - 7;
  const filled = Math.min(barW, Math.round((pctUsed / 100) * barW));
  const empty = barW - filled;
  let barColor = GR;
  if (pctUsed > 80) barColor = RD;
  else if (pctUsed > 50) barColor = YL;
  const pctLabel = `${pctUsed.toFixed(1)}%`.padStart(6);

  const renewStr = billingEnd ? `Renews ${billingEnd}` : '';
  const title = 'OpenCode GO';
  const hPad = ' '.repeat(Math.max(1, W - title.length - renewStr.length));

  const usedStr = `$${totalCost.toFixed(2)} / $${allowance.toFixed(2)}`;
  const remStr = `$${remaining.toFixed(2)} remaining`;
  const cPad = ' '.repeat(Math.max(1, W - usedStr.length - remStr.length));

  console.log('');
  console.log(`  ${CY}${B}${title}${R}${hPad}${DM}${renewStr}${R}`);
  console.log(`  ${DM}${hr}${R}`);
  console.log(`  ${barColor}${'█'.repeat(filled)}${DM}${'░'.repeat(empty)}${R} ${pctLabel}`);
  console.log(`  ${B}${usedStr}${R}${cPad}${GR}${remStr}${R}`);
  console.log(`  ${DM}${hr}${R}`);

  results.forEach(r => {
    const name = r.name.replace(/^[^\s]+@[^\s]+\s+-\s+/, "");
    const display = name.length > 32
      ? name.slice(0, 29) + "..."
      : name.padEnd(32);
    const cost = ('$' + r.cost.toFixed(4)).padStart(10);
    const pct = (((r.cost / allowance) * 100).toFixed(1) + '%').padStart(6);
    console.log(`  ${WH}${display}${R}  ${B}${cost}${R} ${DM}${pct}${R}`);
  });
  console.log('');

} catch (e) {
  console.error("Failed to parse response:", e);
  process.exit(1);
}
PARSEREOF

    printf '\033[1A\033[2K'
    BILLING_PERIOD="$BILLING_PERIOD" BILLING_END="$BILLING_END" node "$PARSER_FILE" "${RESPONSE_FILES[@]}"
}

show_help() {
    echo "${BOLD}OpenCode Go Usage CLI${RESET}"
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  login        Save your auth cookie and workspace config"
    echo "  set-sub-day  Update your billing cycle start day"
    echo "  report       Fetch and display current usage"
}

case "${1:-}" in
    login)          login ;;
    set-sub-day)    set_sub_day ;;
    report)         fetch_and_report ;;
    help|--help|-h) show_help ;;
    *)              show_help; exit 1 ;;
esac
