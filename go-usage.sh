#!/usr/bin/env bash

# OpenCode Go Usage CLI Script
# This script automatically extracts your login cookie from your browser and fetches usage data.

set -e

CONFIG_DIR="${HOME}/.config/opencode/go-usage-bash"
CONFIG_FILE="${CONFIG_DIR}/config.json"
VENV_DIR="${CONFIG_DIR}/venv"
API_URL="https://opencode.ai/_server"

ensure_config_dir() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
    fi
}

login() {
    ensure_config_dir
    
    echo "Please follow these steps:"
    echo "1. Log in to your OpenCode account in the browser"
    echo "2. Open DevTools (F12) → Application → Cookies → https://opencode.ai"
    echo "3. Find the cookie named 'auth'"
    echo "4. Copy its full value (starts with 'Fe26.2**')"
    echo ""
    read -p "Please paste your auth cookie: " AUTH_COOKIE

    if [ -z "$AUTH_COOKIE" ]; then
        echo "Error: Auth cookie cannot be empty."
        exit 1
    fi

    echo "Successfully obtained auth cookie."
    echo ""

    read -p "Workspace ID (press Enter for default 'wrk_01KDSXX2YK0SSF30AKBTQGWQM9'): " WORKSPACE_ID
    WORKSPACE_ID=${WORKSPACE_ID:-wrk_01KDSXX2YK0SSF30AKBTQGWQM9}

    read -p "Server ID (press Enter for default '15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205'): " SERVER_ID
    SERVER_ID=${SERVER_ID:-15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205}

    read -p "Function ID (press Enter for default '31'): " FUNCTION_ID
    FUNCTION_ID=${FUNCTION_ID:-31}

    echo ""
    echo "What day of the month does your billing cycle start?"
    echo "(e.g., if you subscribed on 20-Apr, enter 20)"
    read -p "Subscription day of month (press Enter for default '1'): " SUB_DAY
    SUB_DAY=${SUB_DAY:-1}
    if ! [[ "$SUB_DAY" =~ ^[0-9]+$ ]] || [ "$SUB_DAY" -lt 1 ] || [ "$SUB_DAY" -gt 31 ]; then
        echo "Error: Invalid day. Must be a number between 1 and 31."
        exit 1
    fi

    cat <<EOF > "$CONFIG_FILE"
{
  "authCookie": "$AUTH_COOKIE",
  "workspaceId": "$WORKSPACE_ID",
  "serverId": "$SERVER_ID",
  "functionId": $FUNCTION_ID,
  "subDay": $SUB_DAY
}
EOF
    echo "Configuration saved to $CONFIG_FILE"
}

set_sub_day() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Please run '$0 login' first."
        exit 1
    fi

    CURRENT_SUB_DAY=$(jq -r '.subDay // 1' "$CONFIG_FILE")
    echo "Current billing cycle day: $CURRENT_SUB_DAY"
    echo ""
    echo "What day of the month does your billing cycle start?"
    echo "(e.g., if you subscribed on 20-Apr, enter 20)"
    read -p "Subscription day of month (press Enter for default '1'): " SUB_DAY
    SUB_DAY=${SUB_DAY:-1}
    if ! [[ "$SUB_DAY" =~ ^[0-9]+$ ]] || [ "$SUB_DAY" -lt 1 ] || [ "$SUB_DAY" -gt 31 ]; then
        echo "Error: Invalid day. Must be a number between 1 and 31."
        exit 1
    fi

    TMP_FILE=$(mktemp)
    jq ".subDay = $SUB_DAY" "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"
    echo "Billing cycle day updated to $SUB_DAY"
}

fetch_and_report() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Please run '$0 login' first."
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        echo "Error: 'jq' is required to parse JSON. Please install it (e.g., sudo apt install jq)."
        exit 1
    fi

    AUTH_COOKIE=$(jq -r '.authCookie' "$CONFIG_FILE")
    WORKSPACE_ID=$(jq -r '.workspaceId' "$CONFIG_FILE")
    SERVER_ID=$(jq -r '.serverId' "$CONFIG_FILE")
    FUNCTION_ID=$(jq -r '.functionId' "$CONFIG_FILE")
    SUB_DAY=$(jq -r '.subDay // 1' "$CONFIG_FILE")

    CURRENT_DAY=$(date +%-d)
    CURRENT_MONTH=$(date +%-m)
    CURRENT_YEAR=$(date +%Y)

    # Determine which calendar months are in the current billing cycle
    if [ "$CURRENT_DAY" -lt "$SUB_DAY" ]; then
        # Before sub day: billing cycle spans prev month (from sub day) + current month (up to today)
        PREV_MONTH=$((CURRENT_MONTH - 1))
        if [ "$PREV_MONTH" -eq 0 ]; then
            PREV_MONTH=12
            PREV_YEAR=$((CURRENT_YEAR - 1))
        else
            PREV_YEAR=$CURRENT_YEAR
        fi
        MONTHS_TO_FETCH="$PREV_YEAR:$PREV_MONTH $CURRENT_YEAR:$CURRENT_MONTH"
        MONTH_LABELS=""
        MONTH_NAMES=("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
        PM_IDX=$((PREV_MONTH - 1))
        CM_IDX=$((CURRENT_MONTH - 1))
        MONTH_LABELS="${MONTH_NAMES[$PM_IDX]} $PREV_YEAR + ${MONTH_NAMES[$CM_IDX]} $CURRENT_YEAR"
    else
        # On or after sub day: billing cycle is within the current calendar month
        MONTHS_TO_FETCH="$CURRENT_YEAR:$CURRENT_MONTH"
        MONTH_NAMES=("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
        CM_IDX=$((CURRENT_MONTH - 1))
        MONTH_LABELS="${MONTH_NAMES[$CM_IDX]} $CURRENT_YEAR"
    fi

    # Fetch each month
    RESPONSE_FILES=()
    echo "Fetching usage data from OpenCode..."
    for YM in $MONTHS_TO_FETCH; do
        YEAR="${YM%%:*}"
        MONTH="${YM##*:}"
        JS_MONTH=$((MONTH - 1))

        cat <<EOF > /tmp/go-usage-request.json
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
          -d @/tmp/go-usage-request.json)

        HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
        HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

        if [ "$HTTP_STATUS" -ne 200 ]; then
            rm -f /tmp/go-usage-request.json
            echo "Failed to fetch data. HTTP Status: $HTTP_STATUS"
            echo "Response: $HTTP_BODY"
            exit 1
        fi

        RESPONSE_FILE=$(mktemp /tmp/go-usage-response-XXXXXX)
        echo "$HTTP_BODY" > "$RESPONSE_FILE"
        RESPONSE_FILES+=("$RESPONSE_FILE")
    done

    rm -f /tmp/go-usage-request.json

    # Write the combined parser
    cat << 'PARSEREOF' > /tmp/go-usage-parser.js
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
  keyCosts.forEach((info, keyId) => {
      if (!info.deleted) {
          const costDollars = info.cost / 100000000;
          totalCost += costDollars;
          results.push({ name: info.name, cost: costDollars });
      }
  });

  results.sort((a, b) => b.cost - a.cost);

  console.log("╔════════════════════════════════════════════════════════╗");
  console.log("║ OpenCode GO Usage Report                               ║");
  console.log("╠════════════════════════════════════════════════════════╣");
  console.log("║ Key Name                                        Cost   ║");
  console.log("║--------------------------------------------------------║");

  results.forEach(r => {
      const name = r.name.replace(/^[^\s]+@[^\s]+\s+-\s+/, "");
      const cleanName = name.length > 42 ? name.slice(0, 37) + "..." : name;
      console.log(`║ ${cleanName.padEnd(42)} $${r.cost.toFixed(4).padStart(10)} ║`);
  });

  console.log("║--------------------------------------------------------║");
  console.log(`║ TOTAL                                      $${totalCost.toFixed(4).padStart(10)} ║`);
  console.log("╚════════════════════════════════════════════════════════╝");

  const allowance = 60.0;
  const remaining = allowance - totalCost;
  const pctUsed = (totalCost / allowance) * 100;

  console.log("");
  console.log(`Used: $${totalCost.toFixed(4)} (${pctUsed.toFixed(1)}%)`);
  console.log(`Remaining: $${remaining.toFixed(4)}`);

} catch (e) {
  console.error("Failed to parse response:", e);
  process.exit(1);
}
PARSEREOF

    node /tmp/go-usage-parser.js "${RESPONSE_FILES[@]}"

    # Cleanup
    rm -f /tmp/go-usage-parser.js
    for f in "${RESPONSE_FILES[@]}"; do
        rm -f "$f"
    done
}

case "$1" in
    login)
        login
        ;;
    set-sub-day)
        set_sub_day
        ;;
    report)
        fetch_and_report
        ;;
    *)
        echo "Usage: $0 {login|set-sub-day|report}"
        exit 1
esac
