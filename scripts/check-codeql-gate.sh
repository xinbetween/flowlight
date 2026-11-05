#!/bin/bash
set -euo pipefail

: "${CLASSIFY_RESULT:?CLASSIFY_RESULT is required}"
: "${SWIFT_ROUTE:?SWIFT_ROUTE is required}"
: "${PYTHON_ROUTE:?PYTHON_ROUTE is required}"
: "${ACTIONS_ROUTE:?ACTIONS_ROUTE is required}"
: "${SWIFT_RESULT:?SWIFT_RESULT is required}"
: "${PYTHON_RESULT:?PYTHON_RESULT is required}"
: "${ACTIONS_RESULT:?ACTIONS_RESULT is required}"

if [[ "$CLASSIFY_RESULT" != success ]]; then
  echo "::error::CodeQL classification produced result $CLASSIFY_RESULT."
  exit 1
fi

for language in swift python actions; do
  case "$language" in
    swift) route=$SWIFT_ROUTE; result=$SWIFT_RESULT ;;
    python) route=$PYTHON_ROUTE; result=$PYTHON_RESULT ;;
    actions) route=$ACTIONS_ROUTE; result=$ACTIONS_RESULT ;;
  esac
  case "$route:$result" in
    true:success|false:skipped) ;;
    *)
      echo "::error::CodeQL $language route $route produced result $result."
      exit 1
      ;;
  esac
done
