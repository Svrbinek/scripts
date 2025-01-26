#!/bin/bash

# Nastavení proměnných
INFLUX_HOST="http://localhost:8087"
INFLUX_TOKEN="Gu99cq1AGm-NEyowvFEYQJ2FZyLXGuL6zV9Ucmrn-e2L4RE2eXMOViAZmmq9dRrRNZANTUpA5oeT1zIFVCIbPg=="
INFLUX_ORG="myorg"

# Načtení seznamu tasků
echo "Načítám seznam tasků..."
TASKS=$(curl -s --request GET \
  "$INFLUX_HOST/api/v2/tasks?org=$INFLUX_ORG" \
  --header "Authorization: Token $INFLUX_TOKEN" | jq '.tasks[] | {id: .id, name: .name, status: .status}')

if [[ -z "$TASKS" ]]; then
  echo "Žádné tasky nebyly nalezeny."
else
  echo "Seznam tasků:"
  echo "$TASKS" | jq
fi
