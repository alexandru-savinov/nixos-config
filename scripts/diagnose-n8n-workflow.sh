#!/usr/bin/env bash
#
# Diagnostic script for n8n workflow deployment issues
# Compares source workflow file against deployed database version
#
# Usage: ./diagnose-n8n-workflow.sh <workflow-name>
# Example: ./diagnose-n8n-workflow.sh image-to-anki-worker

set -euo pipefail

WORKFLOW_NAME="${1:-}"
if [[ -z "$WORKFLOW_NAME" ]]; then
  echo "Usage: $0 <workflow-name>" >&2
  echo "Example: $0 image-to-anki-worker" >&2
  exit 1
fi

# Paths
N8N_DIR="/var/lib/n8n"
DB_PATH="$N8N_DIR/database.sqlite"
SOURCE_DIR="n8n-workflows"
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

# Check if database exists
if [[ ! -f "$DB_PATH" ]]; then
  echo -e "${RED}ERROR: n8n database not found: $DB_PATH${NC}" >&2
  exit 1
fi

# Extract workflow ID from source file
WORKFLOW_ID=$(jq -r '.id' "$SOURCE_FILE")
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
trap "rm -f $TEMP_EXPORT" EXIT

echo -e "\n${BLUE}[3] Exporting Current Database Version${NC}"
if sudo -u n8n n8n export:workflow --id="$WORKFLOW_ID" --output="$TEMP_EXPORT" 2>&1 | grep -q "Successfully exported"; then
  echo -e "${GREEN}  ✓ Export successful${NC}"
else
  echo -e "${RED}  ✗ Export failed${NC}"
  exit 1
fi

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
WEBHOOK_PATH=$(jq -r '.nodes[] | select(.type=="n8n-nodes-base.webhook") | .parameters.path' "$SOURCE_FILE" | head -1)
if [[ -n "$WEBHOOK_PATH" ]]; then
  echo "  Expected webhook path: $WEBHOOK_PATH"
  WEBHOOK_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM webhook_entity WHERE webhookPath='$WEBHOOK_PATH';")
  echo "  Registered webhooks: $WEBHOOK_COUNT"
  if [[ "$WEBHOOK_COUNT" -gt 1 ]]; then
    echo -e "${RED}  ✗ Multiple webhooks registered for same path!${NC}"
  fi
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
  echo -e "${BLUE}Recommended fix:${NC}"
  echo "  1. Delete existing workflow: sudo -u n8n n8n delete:workflow --id='$WORKFLOW_ID'"
  echo "  2. Re-import from source: sudo -u n8n n8n import:workflow --input='$SOURCE_FILE'"
  echo "  3. Activate workflow: sudo -u n8n n8n update:workflow --id='$WORKFLOW_ID' --active=true"
  echo "  4. Verify: ./scripts/diagnose-n8n-workflow.sh $WORKFLOW_NAME"
else
  echo -e "${GREEN}  ✓ Workflows are IDENTICAL${NC}"
  echo "  The database version matches the source file."
fi

echo -e "\n${BLUE}=== Diagnostic Complete ===${NC}"
