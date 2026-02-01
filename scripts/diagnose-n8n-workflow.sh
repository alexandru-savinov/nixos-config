#!/usr/bin/env bash
# Diagnostic script to investigate n8n workflow deployment issues
# Usage: ./scripts/diagnose-n8n-workflow.sh <workflow-id>

set -euo pipefail

WORKFLOW_ID="${1:-image-to-anki-worker}"
DB_PATH="/var/lib/n8n/.n8n/database.sqlite"
N8N_URL="http://127.0.0.1:5678"

echo "=== n8n Workflow Deployment Diagnostics ==="
echo "Workflow ID: $WORKFLOW_ID"
echo ""

# 1. Check if workflow exists in database
echo "1. Checking database for workflow..."
if [[ ! -f "$DB_PATH" ]]; then
  echo "ERROR: Database not found at $DB_PATH"
  exit 1
fi

WORKFLOW_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM workflow_entity WHERE id='$WORKFLOW_ID';")
echo "   Found $WORKFLOW_COUNT workflow(s) with ID '$WORKFLOW_ID'"

if [[ "$WORKFLOW_COUNT" -eq 0 ]]; then
  echo "   ERROR: Workflow not in database!"
  exit 1
fi

# 2. Check active state
echo ""
echo "2. Checking active state..."
ACTIVE_STATE=$(sqlite3 "$DB_PATH" "SELECT active FROM workflow_entity WHERE id='$WORKFLOW_ID';")
echo "   Active: $ACTIVE_STATE"

# 3. Check for duplicates by name
echo ""
echo "3. Checking for duplicate workflows by name..."
WORKFLOW_NAME=$(sqlite3 "$DB_PATH" "SELECT name FROM workflow_entity WHERE id='$WORKFLOW_ID';")
echo "   Workflow name: $WORKFLOW_NAME"

DUPLICATES=$(sqlite3 "$DB_PATH" "SELECT id, active FROM workflow_entity WHERE name='$WORKFLOW_NAME';")
DUPLICATE_COUNT=$(echo "$DUPLICATES" | wc -l)
echo "   Found $DUPLICATE_COUNT workflow(s) with name '$WORKFLOW_NAME':"
echo "$DUPLICATES" | while IFS='|' read -r id active; do
  echo "     - ID: $id, Active: $active"
done

# 4. Export current workflow from database
echo ""
echo "4. Exporting workflow from database..."
EXPORT_FILE="/tmp/exported-${WORKFLOW_ID}.json"
n8n export:workflow --id="$WORKFLOW_ID" --output="$EXPORT_FILE" 2>&1 || echo "   Export failed"

if [[ -f "$EXPORT_FILE" ]]; then
  echo "   Exported to: $EXPORT_FILE"

  # 5. Compare key nodes
  echo ""
  echo "5. Comparing workflow structure..."
  SOURCE_FILE="n8n-workflows/${WORKFLOW_ID}.json"

  if [[ -f "$SOURCE_FILE" ]]; then
    SOURCE_NODES=$(jq -r '.nodes | length' "$SOURCE_FILE")
    EXPORTED_NODES=$(jq -r '.nodes | length' "$EXPORT_FILE")

    echo "   Source file nodes: $SOURCE_NODES"
    echo "   Database nodes: $EXPORTED_NODES"

    # Check for TTS-specific nodes (evidence of new workflow)
    SOURCE_HAS_TTS=$(jq -r '.nodes[] | select(.name == "TTS Pre-check") | .name' "$SOURCE_FILE" 2>/dev/null || echo "")
    EXPORTED_HAS_TTS=$(jq -r '.nodes[] | select(.name == "TTS Pre-check") | .name' "$EXPORT_FILE" 2>/dev/null || echo "")

    echo ""
    echo "   Source has 'TTS Pre-check' node: $(if [[ -n "$SOURCE_HAS_TTS" ]]; then echo "YES"; else echo "NO"; fi)"
    echo "   Database has 'TTS Pre-check' node: $(if [[ -n "$EXPORTED_HAS_TTS" ]]; then echo "YES"; else echo "NO"; fi)"

    if [[ -n "$SOURCE_HAS_TTS" && -z "$EXPORTED_HAS_TTS" ]]; then
      echo ""
      echo "   ❌ MISMATCH DETECTED: Source has TTS nodes but database doesn't!"
      echo "   This confirms the workflow import didn't update the database."
    fi
  else
    echo "   Source file not found: $SOURCE_FILE"
  fi
fi

# 6. Check webhook registrations
echo ""
echo "6. Checking webhook registrations..."
WEBHOOK_PATH="anki-worker"
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$N8N_URL/webhook/$WEBHOOK_PATH" 2>/dev/null || echo "000")
echo "   Webhook /$WEBHOOK_PATH response: HTTP $HTTP_CODE"

if [[ "$HTTP_CODE" == "404" ]]; then
  echo "   ⚠️  Webhook not registered (404)"
elif [[ "$HTTP_CODE" == "411" ]]; then
  echo "   ✅ Webhook registered (411 = missing Content-Length for POST)"
fi

# 7. Check n8n service logs for import activity
echo ""
echo "7. Recent n8n-workflow-sync logs:"
journalctl -u n8n-workflow-sync --since "1 hour ago" --no-pager | tail -20 || echo "   No logs available"

echo ""
echo "=== Diagnostics complete ==="
