#!/usr/bin/env bash
# Helper script to use speckit commands with GitHub Copilot CLI
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROMPTS_DIR="$REPO_ROOT/.github/prompts"

show_usage() {
    cat << EOF
Usage: speckit <command> [arguments]

Available commands:
  constitution  - Create or update project constitution
  specify       - Define what you want to build
  plan          - Create technical implementation plan
  tasks         - Generate actionable task list
  implement     - Execute implementation
  clarify       - Clarify underspecified areas
  analyze       - Cross-artifact consistency analysis
  checklist     - Generate quality checklists

Usage with GitHub Copilot CLI:
  speckit constitution "Create principles for NixOS configuration"
  
This will print the prompt that you can paste into: github-copilot-cli what-the-shell
EOF
}

if [ $# -eq 0 ]; then
    show_usage
    exit 1
fi

COMMAND="$1"
shift
ARGS="$*"

PROMPT_FILE="$PROMPTS_DIR/speckit.$COMMAND.prompt.md"

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: Unknown command '$COMMAND'"
    echo ""
    show_usage
    exit 1
fi

# Read the prompt and substitute arguments
PROMPT_CONTENT=$(cat "$PROMPT_FILE" | sed "s/\$ARGUMENTS/$ARGS/g")

echo "=========================================="
echo "Spec-Kit Prompt for: $COMMAND"
echo "=========================================="
echo ""
echo "$PROMPT_CONTENT"
echo ""
echo "=========================================="
echo "Copy the above prompt and use it with your AI assistant"
echo "Or pipe to GitHub Copilot CLI:"
echo "  echo '<your query>' | github-copilot-cli what-the-shell"
echo "=========================================="
