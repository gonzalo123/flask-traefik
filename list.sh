#!/bin/bash

BLUE='\033[0;34m'
NC='\033[0m'

services=$(docker service ls --format "{{.ID}}|{{.Name}}")

for service in $services; do
    service_id=$(echo "$service" | cut -d "|" -f1)
    service_name=$(echo "$service" | cut -d "|" -f2)

    labels=$(docker service inspect "$service_id" | grep traefik.http.routers.app.rule)
    rule=$(echo "$labels" | sed 's/.*PathPrefix(\(`[^`]*`\)).*/\1/' | sed 's/`//g') # Eliminar las comillas invertidas

    if [[ -n $rule ]]; then
        echo -e "${BLUE}$service_name${NC} $rule"
    fi
done
echo ""

