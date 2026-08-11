#!/bin/bash
# .claude/hooks/pre-compact-kg-export.sh
# Automatically exports knowledge graph before context compaction

set -e

KG_FILE="$CLAUDE_PROJECT_DIR/.knowledge-graph/graph.json"

echo "💾 Pre-compaction: Saving knowledge graph..."
echo ""
echo "📊 Claude should export knowledge graph to $KG_FILE before compaction"
echo "   This ensures all session learnings are preserved across the context boundary"
echo ""

exit 0
