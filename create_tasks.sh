#!/bin/bash

# Uchovávejte pouze posledních 1000 řádků logu
LOG_FILE=~/scripts/logs/create_tasks.log
if [ -f "$LOG_FILE" ]; then
  tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp"
  mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# Nastavení proměnných
INFLUX_HOST="http://localhost:8087"
INFLUX_TOKEN="Gu99cq1AGm-NEyowvFEYQJ2FZyLXGuL6zV9Ucmrn-e2L4RE2eXMOViAZmmq9dRrRNZANTUpA5oeT1zIFVCIbPg=="
INFLUX_ORG="myorg"
SOURCE_BUCKET="homeassistant"

# Definice agregací
declare -A AGGREGATIONS=(
  ["1m"]="homeassistant_1m:1m:homeassistant"
  ["5m"]="homeassistant_5m:5m:homeassistant_1m"
  ["10m"]="homeassistant_10m:10m:homeassistant_5m"
  ["1h"]="homeassistant_1h:1h:homeassistant_10m"
  ["1d"]="homeassistant_1d:1d:homeassistant_1h"
)

# Upravená funkce sanitize_measurement bez debug výstupů
sanitize_measurement() {
  local measurement="$1"

  # Odstranění neviditelných znaků
  measurement=$(echo "$measurement" | tr -d '\r\n')

  # Sanitizace podle pravidel
  case "$measurement" in
    "Signal %") echo "Signal_Percent" ;;
    "%") echo "Percent" ;;
    "°") echo "Degrees" ;;
    "°C") echo "DegreesC" ;;
    "m³") echo "mCubic" ;;
    "m³/h") echo "mCubic_h" ;;
    "") echo "UnknownMeasurement" ;;
    *) echo "$measurement" ;;
  esac
}

# Funkce pro kontrolu existence tasku
task_exists() {
  local task_name="$1"
  local response=$(curl -s --request GET \
    "$INFLUX_HOST/api/v2/tasks?name=$task_name&org=$INFLUX_ORG" \
    --header "Authorization: Token $INFLUX_TOKEN")

  if echo "$response" | grep -q '"name":"'$task_name'"'; then
    return 0  # Task exists
  else
    return 1  # Task does not exist
  fi
}

# Načtení seznamu měření z InfluxDB
echo "Načítám seznam _measurement z bucketu '$SOURCE_BUCKET'..."
RAW_RESPONSE=$(curl -s --request POST \
  "$INFLUX_HOST/api/v2/query?org=$INFLUX_ORG" \
  --header "Authorization: Token $INFLUX_TOKEN" \
  --header "Content-Type: application/vnd.flux" \
  --data 'import "influxdata/influxdb/schema"
schema.measurements(bucket: "'"$SOURCE_BUCKET"'")')

# Kontrola odpovědi
if [[ -z "$RAW_RESPONSE" ]]; then
  echo "Chyba: Odpověď z InfluxDB je prázdná!"
  exit 1
fi

# Extrakce měření
MEASUREMENTS=$(echo "$RAW_RESPONSE" | awk -F',' '
  NR > 1 {
    if ($4 != "") {
      gsub(/^[ \t]+|[ \t]+$/, "", $4)
      gsub(/[\r\n]/, "", $4)
      if ($4 != "") print $4
    }
  }
' | sort -u)

# Kontrola načtených měření
if [[ -z "$MEASUREMENTS" ]]; then
  echo "Chyba: Žádná měření nebyla nalezena."
  exit 1
else
  echo "Načtená měření:"
  echo "$MEASUREMENTS"
fi

# Generování a vytváření tasků
echo "Vytvářím tasky pro agregaci dat..."
while IFS= read -r MEASUREMENT; do
  for PERIOD in "${!AGGREGATIONS[@]}"; do
    IFS=':' read -r DEST_BUCKET RANGE SOURCE_B <<< "${AGGREGATIONS[$PERIOD]}"
    SANITIZED_MEASUREMENT=$(sanitize_measurement "$MEASUREMENT")
    TASK_NAME="aggregate_${SANITIZED_MEASUREMENT}_${PERIOD}"

    # Kontrola existence tasku
    if task_exists "$TASK_NAME"; then
      echo "Task '$TASK_NAME' již existuje. Přeskakuji."
      continue
    fi

    FLUX_SCRIPT=$(cat <<EOF
option task = {name: "${TASK_NAME}", every: ${PERIOD}}

from(bucket: "${SOURCE_B}")
  |> range(start: -${RANGE})
  |> filter(fn: (r) => r["_measurement"] == "${MEASUREMENT}")
  |> filter(fn: (r) => r["_field"] == "value")
  |> aggregateWindow(every: ${PERIOD}, fn: mean, createEmpty: false)
  |> group(columns: ["_measurement", "domain", "entity_id", "source"], mode: "by")
  |> to(bucket: "${DEST_BUCKET}", org: "${INFLUX_ORG}")
EOF
    )

    # Vytvoření tasku v InfluxDB
    RESPONSE=$(curl -s --request POST \
      "$INFLUX_HOST/api/v2/tasks" \
      --header "Authorization: Token $INFLUX_TOKEN" \
      --header "Content-Type: application/json" \
      --data-binary @- <<EOF
{
  "org": "${INFLUX_ORG}",
  "flux": $(jq -Rs <<<"$FLUX_SCRIPT")
}
EOF
    )

    if echo "$RESPONSE" | grep -q '"status":"active"'; then
      echo "Task '${TASK_NAME}' úspěšně vytvořen."
    elif echo "$RESPONSE" | grep -q '"code":"conflict"'; then
      echo "Task '${TASK_NAME}' již existuje."
    else
      echo "CHYBA při vytváření tasku '${TASK_NAME}':"
      echo "$RESPONSE"
    fi
  done
done <<< "$MEASUREMENTS"

# Ovněření existence tasků
echo "Existující tasky:"
curl -s --request GET \
  "$INFLUX_HOST/api/v2/tasks" \
  --header "Authorization: Token $INFLUX_TOKEN" | jq '.tasks[].name'

echo "Všechny tasky byly úspěšně vytvořeny!"
