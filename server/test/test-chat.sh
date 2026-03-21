#!/bin/bash
# VisionClaude Gateway test scripts

BASE_URL="${1:-http://localhost:18790}"

echo "=== Health Check ==="
curl -s "$BASE_URL/health" | python3 -m json.tool
echo ""

echo "=== List Tools ==="
curl -s "$BASE_URL/tools" | python3 -m json.tool
echo ""

echo "=== Text-only Chat ==="
curl -s -X POST "$BASE_URL/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Hello! What tools do you have available? List them briefly."
  }' | python3 -m json.tool
echo ""

echo "=== Get Config ==="
curl -s "$BASE_URL/config" | python3 -m json.tool
echo ""

echo "=== MCP Health ==="
curl -s "$BASE_URL/tools/health" | python3 -m json.tool
echo ""
