#!/bin/bash

# Nastavení proměnných
INFLUX_HOST="http://localhost:8087"
INFLUX_TOKEN="Gu99cq1AGm-NEyowvFEYQJ2FZyLXGuL6zV9Ucmrn-e2L4RE2eXMOViAZmmq9dRrRNZANTUpA5oeT1zIFVCIbPg=="
INFLUX_ORG="myorg"

# Smyčka pro opakované mazání
while :; do
  echo "Načítám seznam tasků..."
  TASK_IDS=$(curl -s --request GET \
    "$INFLUX_HOST/api/v2/tasks?org=$INFLUX_ORG" \
    --header "Authorization: Token $INFLUX_TOKEN" \
    | jq -r '.tasks[].id')

  if [[ -z "$TASK_IDS" ]]; then
    echo "Žádné další tasky k mazání. Hotovo!"
    break
  fi

  for TASK_ID in $TASK_IDS; do
    echo "Mažu task s ID: $TASK_ID"
    curl -s --request DELETE \
      "$INFLUX_HOST/api/v2/tasks/$TASK_ID" \
      --header "Authorization: Token $INFLUX_TOKEN" > /dev/null
  done
done
