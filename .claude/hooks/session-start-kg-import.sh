#!/bin/bash
# .claude/hooks/session-start-kg-import.sh
# Automatically imports knowledge graph at session start

set -e

KG_FILE="$CLAUDE_PROJECT_DIR/.knowledge-graph/graph.json"

exec 2>&1

if [ ! -f "$KG_FILE" ]; then
  echo "ℹ️  No knowledge graph found - this may be a new repository"
  exit 0
fi

echo "💡 Knowledge graph available at $KG_FILE"
echo "📊 Claude will check if KG is loaded and import automatically if needed"
echo ""

exit 0
