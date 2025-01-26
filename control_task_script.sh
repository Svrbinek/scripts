# script pro kontrolu tasků

#!/bin/bash

# Nastavení proměnných
INFLUX_HOST="http://localhost:8087"
INFLUX_TOKEN="Gu99cq1AGm-NEyowvFEYQJ2FZyLXGuL6zV9Ucmrn-e2L4RE2eXMOViAZmmq9dRrRNZANTUpA5oeT1zIFVCIbPg=="
INFLUX_ORG="myorg"

# Načtení seznamu tasků
TASK_IDS=$(curl -s --request GET \
  "$INFLUX_HOST/api/v2/tasks?org=$INFLUX_ORG" \
  --header "Authorization: Token $INFLUX_TOKEN" \
  | jq -r '.tasks[].id')

if [[ -z "$TASK_IDS" ]]; then
  echo "Žádné tasky nebyly nalezeny."
  exit 1
fi

# Výpis detailů každého tasku
echo "Načítám detaily tasků..."
for TASK_ID in $TASK_IDS; do
  echo "Task ID: $TASK_ID"
  RESPONSE=$(curl -s --request GET \
    "$INFLUX_HOST/api/v2/tasks/$TASK_ID" \
    --header "Authorization: Token $INFLUX_TOKEN")

  # Extrakce názvu a Flux kódu
  TASK_NAME=$(echo "$RESPONSE" | jq -r '.name')
  FLUX_CODE=$(echo "$RESPONSE" | jq -r '.flux')

  echo "Task Name: $TASK_NAME"
  echo "Flux Code:"
  echo "$FLUX_CODE"
  echo "--------------------------------------"
done
