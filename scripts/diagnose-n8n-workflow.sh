#!/usr/bin/env bash
#
# Diagnostic script for n8n workflow deployment issues
# Compares source workflow file against deployed database version
#
# Usage: ./diagnose-n8n-workflow.sh <workflow-name>
# Example: ./diagnose-n8n-workflow.sh image-to-anki-worker

set -euo pipefail

# Check required dependencies
for cmd in jq sqlite3 sha256sum curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command '$cmd' not found" >&2
    exit 1
  fi
done

# Find n8n binary from systemd service (not in PATH by default on NixOS)
# Note: systemctl show returns exit code 0 even for missing services, so check output instead
EXEC_START=$(systemctl show n8n -p ExecStart --value 2>/dev/null)
if [[ -z "$EXEC_START" ]]; then
  echo "ERROR: n8n.service not found or has no ExecStart (is n8n installed?)" >&2
  exit 1
fi
N8N_BIN=$(echo "$EXEC_START" | grep -oP '/nix/store/[^ ;]+/bin/n8n' | head -1)
if [[ -z "$N8N_BIN" ]]; then
  echo "ERROR: Could not extract n8n binary path from ExecStart: $EXEC_START" >&2
  exit 1
fi
if [[ ! -x "$N8N_BIN" ]]; then
  echo "ERROR: n8n binary not executable (garbage collected?): $N8N_BIN" >&2
  exit 1
fi

WORKFLOW_NAME="${1:-}"
if [[ -z "$WORKFLOW_NAME" ]]; then
  echo "Usage: $0 <workflow-name>" >&2
  echo "Example: $0 image-to-anki-worker" >&2
  exit 1
fi

# Paths
N8N_DIR="/var/lib/n8n"
# n8n stores its database in ~/.n8n/ which is /var/lib/n8n/.n8n/ when run as n8n user
DB_PATH="$N8N_DIR/.n8n/database.sqlite"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="$REPO_ROOT/n8n-workflows"
SOURCE_FILE="$SOURCE_DIR/${WORKFLOW_NAME}.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== n8n Workflow Diagnostic Tool ===${NC}"
echo -e "Workflow: ${YELLOW}${WORKFLOW_NAME}${NC}\n"

# Check if source file exists
if [[ ! -f "$SOURCE_FILE" ]]; then
  echo -e "${RED}ERROR: Source file not found: $SOURCE_FILE${NC}" >&2
  exit 1
fi

# Validate source file is valid JSON
if ! jq empty "$SOURCE_FILE" 2>/dev/null; then
  echo -e "${RED}ERROR: Source file is not valid JSON: $SOURCE_FILE${NC}" >&2
  exit 1
fi

# Check if database exists
if [[ ! -f "$DB_PATH" ]]; then
  echo -e "${RED}ERROR: n8n database not found: $DB_PATH${NC}" >&2
  exit 1
fi

# Extract workflow ID from source file
WORKFLOW_ID=$(jq -r '.id' "$SOURCE_FILE")

# Validate workflow ID format to prevent SQL injection
if [[ ! "$WORKFLOW_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo -e "${RED}ERROR: Invalid workflow ID format: $WORKFLOW_ID${NC}" >&2
  exit 1
fi

echo -e "${BLUE}[1] Source File Analysis${NC}"
echo "  File: $SOURCE_FILE"
echo "  Workflow ID: $WORKFLOW_ID"
echo "  Nodes count: $(jq '.nodes | length' "$SOURCE_FILE")"
echo "  Connections count: $(jq '.connections | length' "$SOURCE_FILE")"
echo ""

# Check if workflow exists in database
echo -e "${BLUE}[2] Database Check${NC}"
DB_EXISTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM workflow_entity WHERE id='$WORKFLOW_ID';")
if [[ "$DB_EXISTS" == "0" ]]; then
  echo -e "${RED}  ✗ Workflow NOT found in database${NC}"
  echo -e "  ${YELLOW}Action: Run 'n8n import:workflow --input=$SOURCE_FILE' to create it${NC}"
  exit 0
else
  echo -e "${GREEN}  ✓ Workflow found in database${NC}"
fi

# Export current workflow from database
TEMP_EXPORT=$(mktemp)
trap 'rm -f "$TEMP_EXPORT" "${TEMP_EXPORT}.tmp"' EXIT

echo -e "\n${BLUE}[3] Exporting Current Database Version${NC}"
EXPORT_ERR=$(N8N_USER_FOLDER="$N8N_DIR" N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false "$N8N_BIN" export:workflow --id="$WORKFLOW_ID" --output="$TEMP_EXPORT" 2>&1 >/dev/null) || {
  echo -e "${RED}  ✗ Export command failed${NC}"
  [[ -n "$EXPORT_ERR" ]] && echo "  $(echo "$EXPORT_ERR" | sed 's/\x1b\[[0-9;]*m//g' | head -5)"
  exit 1
}
# n8n export wraps output in an array; unwrap to plain object
if jq -e 'type == "array"' "$TEMP_EXPORT" &>/dev/null; then
  ARRAY_LEN=$(jq 'length' "$TEMP_EXPORT")
  if [[ "$ARRAY_LEN" -eq 0 ]]; then
    echo -e "${RED}  ✗ Export returned empty array${NC}"
    exit 1
  fi
  if [[ "$ARRAY_LEN" -gt 1 ]]; then
    echo -e "${YELLOW}  ⚠ Export returned $ARRAY_LEN workflows; using first element${NC}"
  fi
  jq '.[0]' "$TEMP_EXPORT" > "${TEMP_EXPORT}.tmp" && mv "${TEMP_EXPORT}.tmp" "$TEMP_EXPORT"
fi
if [[ ! -s "$TEMP_EXPORT" ]] || ! jq -e 'type == "object"' "$TEMP_EXPORT" &>/dev/null; then
  echo -e "${RED}  ✗ Export produced invalid output${NC}"
  exit 1
fi
echo -e "${GREEN}  ✓ Export successful${NC}"

# Compare node counts
SOURCE_NODE_COUNT=$(jq '.nodes | length' "$SOURCE_FILE")
DB_NODE_COUNT=$(jq '.nodes | length' "$TEMP_EXPORT")

echo -e "\n${BLUE}[4] Node Count Comparison${NC}"
echo "  Source: $SOURCE_NODE_COUNT nodes"
echo "  Database: $DB_NODE_COUNT nodes"
if [[ "$SOURCE_NODE_COUNT" != "$DB_NODE_COUNT" ]]; then
  echo -e "${RED}  ✗ NODE COUNT MISMATCH!${NC}"
else
  echo -e "${GREEN}  ✓ Node counts match${NC}"
fi

# Compare node types and names
echo -e "\n${BLUE}[5] Node Structure Analysis${NC}"
echo "  Source nodes:"
jq -r '.nodes[] | "    - \(.name) (\(.type))"' "$SOURCE_FILE"
echo ""
echo "  Database nodes:"
jq -r '.nodes[] | "    - \(.name) (\(.type))"' "$TEMP_EXPORT"

# Check for specific TTS nodes (related to issue #157, #161)
echo -e "\n${BLUE}[6] TTS Audio Nodes Check${NC}"
SOURCE_HAS_TTS=$(jq '[.nodes[] | select(.name | contains("TTS") or contains("audio"))] | length' "$SOURCE_FILE")
DB_HAS_TTS=$(jq '[.nodes[] | select(.name | contains("TTS") or contains("audio"))] | length' "$TEMP_EXPORT")

echo "  Source TTS/audio nodes: $SOURCE_HAS_TTS"
echo "  Database TTS/audio nodes: $DB_HAS_TTS"

if [[ "$SOURCE_HAS_TTS" != "$DB_HAS_TTS" ]]; then
  echo -e "${RED}  ✗ TTS node mismatch - this explains why audio features aren't working!${NC}"
fi

# Check for duplicates
echo -e "\n${BLUE}[7] Duplicate Workflow Check${NC}"
DUPLICATE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM workflow_entity WHERE name=(SELECT name FROM workflow_entity WHERE id='$WORKFLOW_ID');")
if [[ "$DUPLICATE_COUNT" -gt 1 ]]; then
  echo -e "${RED}  ✗ Found $DUPLICATE_COUNT workflows with the same name!${NC}"
  sqlite3 "$DB_PATH" "SELECT id, name, active, updatedAt FROM workflow_entity WHERE name=(SELECT name FROM workflow_entity WHERE id='$WORKFLOW_ID');" | while read -r line; do
    echo "    $line"
  done
else
  echo -e "${GREEN}  ✓ No duplicates found${NC}"
fi

# Check webhook registration
echo -e "\n${BLUE}[8] Webhook Registration${NC}"
WEBHOOK_PATH=$(jq -r '.nodes[] | select(.type=="n8n-nodes-base.webhook") | .parameters.path // empty' "$SOURCE_FILE" | head -1)
if [[ -n "$WEBHOOK_PATH" && "$WEBHOOK_PATH" != "null" ]]; then
  echo "  Expected webhook path: $WEBHOOK_PATH"
  # Validate path format before SQL query (prevent injection from crafted source files)
  if [[ ! "$WEBHOOK_PATH" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
    echo -e "${YELLOW}  Webhook path contains unexpected characters, skipping DB check${NC}"
    WEBHOOK_COUNT=0
  else
    WEBHOOK_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM webhook_entity WHERE webhookPath='$WEBHOOK_PATH';")
  fi
  echo "  Registered in database: $WEBHOOK_COUNT"
  if [[ "$WEBHOOK_COUNT" -gt 1 ]]; then
    echo -e "${RED}  ✗ Multiple webhooks registered for same path!${NC}"
  fi

  # Live check: verify webhook responds (catches stale DB registration)
  # Only probe GET webhooks (read-only, safe to call); skip POST webhooks to avoid side effects
  WEBHOOK_METHOD=$(jq -r '.nodes[] | select(.type=="n8n-nodes-base.webhook") | .parameters.httpMethod // "GET"' "$SOURCE_FILE" | head -1)
  if [[ "$WEBHOOK_METHOD" != "GET" ]]; then
    echo -e "${YELLOW}  Skipping live check ($WEBHOOK_METHOD webhook — probe would trigger execution)${NC}"
  else
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:5678/webhook/$WEBHOOK_PATH" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" || "$HTTP_CODE" == "202" ]]; then
      echo -e "${GREEN}  ✓ Webhook is live (HTTP $HTTP_CODE)${NC}"
    elif [[ "$HTTP_CODE" == "404" ]]; then
      echo -e "${RED}  ✗ Webhook returns 404 — not loaded in memory${NC}"
      echo -e "  ${YELLOW}Action: sudo systemctl restart n8n${NC}"
    elif [[ "$HTTP_CODE" == "000" ]]; then
      echo -e "${YELLOW}  ⚠ Cannot reach n8n (is it running?)${NC}"
    else
      echo -e "${YELLOW}  ⚠ Webhook returned HTTP $HTTP_CODE${NC}"
    fi
  fi
else
  echo "  No webhook nodes found (skipped)"
fi

# Compare full workflow JSON (hash-based)
echo -e "\n${BLUE}[9] Full Content Comparison${NC}"
SOURCE_HASH=$(jq -S '.nodes, .connections' "$SOURCE_FILE" | sha256sum | cut -d' ' -f1)
DB_HASH=$(jq -S '.nodes, .connections' "$TEMP_EXPORT" | sha256sum | cut -d' ' -f1)

echo "  Source hash: $SOURCE_HASH"
echo "  Database hash: $DB_HASH"

if [[ "$SOURCE_HASH" != "$DB_HASH" ]]; then
  echo -e "${RED}  ✗ WORKFLOWS ARE DIFFERENT!${NC}"
  echo -e "  ${YELLOW}The database version does NOT match the source file.${NC}"
  echo ""
  echo -e "${YELLOW}This confirms the deployment issue:${NC}"
  echo "  - 'n8n import:workflow' reports success but doesn't update existing workflows"
  echo "  - Database still contains old workflow definition"
  echo "  - Service restarts load old code from database"
  echo ""
  N8N_ENV="N8N_USER_FOLDER=$N8N_DIR N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false"
  echo -e "${BLUE}Recommended fix:${NC}"
  echo "  1. Delete existing workflow: $N8N_ENV $N8N_BIN delete:workflow --id='$WORKFLOW_ID'"
  echo "  2. Re-import from source: $N8N_ENV $N8N_BIN import:workflow --input='$SOURCE_FILE'"
  echo "  3. Activate workflow: $N8N_ENV $N8N_BIN update:workflow --id='$WORKFLOW_ID' --active=true"
  echo "  4. Restart n8n: sudo systemctl restart n8n"
  echo "  5. Verify: ./scripts/diagnose-n8n-workflow.sh $WORKFLOW_NAME"
else
  echo -e "${GREEN}  ✓ Workflows are IDENTICAL${NC}"
  echo "  The database version matches the source file."
fi

echo -e "\n${BLUE}=== Diagnostic Complete ===${NC}"
