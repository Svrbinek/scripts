#!/bin/bash

# Nastavení proměnných
INFLUX_HOST="http://localhost:8087"
INFLUX_TOKEN="Gu99cq1AGm-NEyowvFEYQJ2FZyLXGuL6zV9Ucmrn-e2L4RE2eXMOViAZmmq9dRrRNZANTUpA5oeT1zIFVCIbPg=="
INFLUX_ORG="myorg"
SOURCE_BUCKET="homeassistant"
DEST_BUCKET="homeassistant_1m"

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

# Zobrazení odpovědi pro ladění
echo "Odpověď z InfluxDB:"
echo "$RAW_RESPONSE"

# Oprava extrakce měření
MEASUREMENTS=$(echo "$RAW_RESPONSE" | awk -F',' '
  NR > 1 { 
    if ($4 != "") {
      # Odstranění mezer a znaků nového řádku
      gsub(/^[ \t]+|[ \t]+$/, "", $4)
      gsub(/[\r\n]/, "", $4)
      if ($4 != "") print $4
    }
  }
' | sort -u)

# Debug výpis pro kontrolu
echo "Debug: Načtená měření (jeden řádek = jedno měření):"
while IFS= read -r MEASUREMENT; do
  echo ">> '$MEASUREMENT'"
done <<< "$MEASUREMENTS"

# Kontrola načtených měření
if [[ -z "$MEASUREMENTS" ]]; then
  echo "Chyba: Žádná měření nebyla nalezena."
  exit 1
else
  echo "Načtená měření:"
  echo "$MEASUREMENTS"
fi

# Definice agregací
declare -A AGGREGATIONS=(
  ["1m"]="homeassistant_1m:1m:homeassistant"
  ["5m"]="homeassistant_5m:5m:homeassistant_1m"
  ["10m"]="homeassistant_10m:10m:homeassistant_5m"
  ["1h"]="homeassistant_1h:1h:homeassistant_10m"
  ["1d"]="homeassistant_1d:1d:homeassistant_1h"
)

echo "Vytvářím tasky pro agregaci dat..."
while IFS= read -r MEASUREMENT; do
  for PERIOD in "${!AGGREGATIONS[@]}"; do
    IFS=':' read -r DEST_BUCKET RANGE SOURCE_B <<< "${AGGREGATIONS[$PERIOD]}"
    SANITIZED_MEASUREMENT=$(sanitize_measurement "$MEASUREMENT")
    TASK_NAME="aggregate_${SANITIZED_MEASUREMENT}_${PERIOD}"
    
    echo "DEBUG: Vytvářím task '$TASK_NAME'"
    echo "DEBUG: Měření: '$MEASUREMENT'"
    
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

    echo "DEBUG: Flux script:"
    echo "$FLUX_SCRIPT"

    # Vytvoření tasku v InfluxDB
    RESPONSE=$(curl -v --request POST \
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

    echo "DEBUG: InfluxDB API Response:"
    echo "$RESPONSE" | jq '.'

    # Kontrola vytvoření tasku
    if echo "$RESPONSE" | grep -q '"status":"active"'; then
      echo "Task '${TASK_NAME}' úspěšně vytvořen a je aktivní."
    elif echo "$RESPONSE" | grep -q '"code":"conflict"'; then
      echo "Task '${TASK_NAME}' již existuje."
    else
      echo "CHYBA při vytváření tasku '${TASK_NAME}':"
      echo "$RESPONSE"
      exit 1
    fi
  done
done <<< "$MEASUREMENTS"

# Ověření existence tasků
curl -s --request GET \
  "$INFLUX_HOST/api/v2/tasks" \
  --header "Authorization: Token $INFLUX_TOKEN" | jq '.tasks[].name'

echo "Všechny tasky byly vytvořeny!"
