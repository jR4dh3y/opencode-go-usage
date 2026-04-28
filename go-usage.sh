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

    echo "✅ Successfully obtained auth cookie."
    echo ""

    read -p "Workspace ID (press Enter for default 'wrk_01KDSXX2YK0SSF30AKBTQGWQM9'): " WORKSPACE_ID
    WORKSPACE_ID=${WORKSPACE_ID:-wrk_01KDSXX2YK0SSF30AKBTQGWQM9}

    read -p "Server ID (press Enter for default '15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205'): " SERVER_ID
    SERVER_ID=${SERVER_ID:-15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205}

    read -p "Function ID (press Enter for default '31'): " FUNCTION_ID
    FUNCTION_ID=${FUNCTION_ID:-31}

    cat <<EOF > "$CONFIG_FILE"
{
  "authCookie": "$AUTH_COOKIE",
  "workspaceId": "$WORKSPACE_ID",
  "serverId": "$SERVER_ID",
  "functionId": $FUNCTION_ID
}
EOF
    echo "✅ Configuration saved to $CONFIG_FILE"
}

fetch_and_report() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Please run '$0 login' first."
        exit 1
    fi

    # Read config using jq
    if ! command -v jq &> /dev/null; then
        echo "Error: 'jq' is required to parse JSON. Please install it (e.g., sudo apt install jq)."
        exit 1
    fi

    AUTH_COOKIE=$(jq -r '.authCookie' "$CONFIG_FILE")
    WORKSPACE_ID=$(jq -r '.workspaceId' "$CONFIG_FILE")
    SERVER_ID=$(jq -r '.serverId' "$CONFIG_FILE")
    FUNCTION_ID=$(jq -r '.functionId' "$CONFIG_FILE")

    YEAR=$(date +%Y)
    # Javascript months are 0-indexed, so we subtract 1 from the current month
    MONTH=$(($(date +%-m) - 1))

    # Construct the POST body
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
      { "t": 0, "s": $MONTH },
      { "t": 1, "s": "UTC" }
    ]
  },
  "f": $FUNCTION_ID,
  "m": []
}
EOF

    echo "Fetching usage data from OpenCode..."
    # We use curl to fetch data
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

    rm /tmp/go-usage-request.json

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "Failed to fetch data. HTTP Status: $HTTP_STATUS"
        echo "Response: $HTTP_BODY"
        exit 1
    fi

    cat << 'EOF' > /tmp/go-usage-parser.js
const fs = require('fs');
const text = fs.readFileSync(0, 'utf-8');

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

try {
  let parsed;
  if (text.includes('text/javascript') || text.startsWith(';0x')) {
      parsed = parseJsResponse(text);
  } else {
      parsed = JSON.parse(text);
  }
  
  const unwrapped = unwrapValue(parsed);
  
  const usage = Array.isArray(unwrapped?.usage) ? unwrapped.usage : (Array.isArray(unwrapped) ? unwrapped : []);
  const keys = Array.isArray(unwrapped?.keys) ? unwrapped.keys : [];

  
  const keyCosts = new Map();
  keys.forEach(k => {
      if (!k.deleted) {
          keyCosts.set(k.id, { cost: 0, name: k.displayName || "Unknown Key", deleted: false });
      }
  });

  usage.forEach(row => {
      if (row.plan !== "sub" && row.plan !== "lite") return;
      const keyId = row.keyId || "unknown";
      const cost = row.totalCost || 0;
      
      if (!keyCosts.has(keyId)) {
          const keyInfo = keys.find(k => k.id === keyId);
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

  console.log("╔════════════════════════════════════════════════════════════════════╗");
  console.log("║ OpenCode GO Usage Report                                           ║");
  console.log("╠════════════════════════════════════════════════════════════════════╣");
  console.log("║ Key Name                                       Cost       Status   ║");
  console.log("║--------------------------------------------------------------------║");
  
  results.forEach(r => {
      const name = r.name.replace(/^[^\s]+@[^\s]+\s+-\s+/, "");
      const cleanName = name.length > 41 ? name.slice(0, 38) + "..." : name;
      console.log(`║ ${cleanName.padEnd(42)} $${r.cost.toFixed(4).padStart(10)}    active   ║`);
  });

  console.log("║--------------------------------------------------------------------║");
  console.log(`║ TOTAL                                      $${totalCost.toFixed(4).padStart(10)}             ║`);
  console.log("╚════════════════════════════════════════════════════════════════════╝");
  
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
EOF

    echo "$HTTP_BODY" | node /tmp/go-usage-parser.js
    rm /tmp/go-usage-parser.js
}

case "$1" in
    login)
        login
        ;;
    report)
        fetch_and_report
        ;;
    *)
        echo "Usage: $0 {login|report}"
        exit 1
esac
