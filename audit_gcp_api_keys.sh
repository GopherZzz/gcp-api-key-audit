#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# GCP Organisation API Key Audit Script
#
# Analyses all projects in your GCP organisation for:
#   - Projects with Generative AI APIs enabled
#   - Unrestricted API keys
#   - API keys granting access to AI APIs
# ─────────────────────────────────────────────────────────────────────────────

TARGET_APIS=("generativelanguage.googleapis.com" "aiplatform.googleapis.com")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

divider() {
  printf "${DIM}%-80s${NC}\n" | tr ' ' '─'
}

header() {
  echo ""
  divider
  printf "${BOLD}${BLUE}  STAGE %s: %s${NC}\n" "$1" "$2"
  divider
  echo ""
}

info()    { printf "  ${CYAN}ℹ${NC}  %s\n" "$1"; }
ok()      { printf "  ${GREEN}✔${NC}  %s\n" "$1"; }
warn()    { printf "  ${YELLOW}⚠${NC}  %s\n" "$1"; }
alert()   { printf "  ${RED}✘${NC}  %s\n" "$1"; }
bullet()  { printf "      • %s\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 1: List all projects
# ─────────────────────────────────────────────────────────────────────────────
header 1 "Discovering all GCP projects"

PROJECT_IDS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && PROJECT_IDS+=("$line")
done < <(gcloud projects list --format="value(projectId)" --sort-by=projectId 2>/dev/null)

if [[ ${#PROJECT_IDS[@]} -eq 0 ]]; then
  alert "No projects found. Check your gcloud auth and permissions."
  exit 1
fi

ok "Found ${BOLD}${#PROJECT_IDS[@]}${NC} projects"
echo ""
for pid in "${PROJECT_IDS[@]}"; do
  bullet "$pid"
done

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 2: Find projects with target AI APIs enabled
# ─────────────────────────────────────────────────────────────────────────────
header 2 "Checking which projects have AI APIs enabled"
info "Looking for: ${TARGET_APIS[*]}"
echo ""

# Parallel arrays to track project -> enabled APIs mapping (bash 3 compatible)
AI_PROJECTS=()
AI_PROJECTS_APIS=()    # matched APIs per project, same index as AI_PROJECTS
AI_PROJECTS_APIKEYS_ENABLED=()  # "yes"/"no" — whether apikeys.googleapis.com is enabled

# Track apikeys API status for ALL projects (used in stage 4)
ALL_PROJECTS_APIKEYS_ENABLED=()  # same index as PROJECT_IDS

for pid in "${PROJECT_IDS[@]}"; do
  printf "  ${DIM}Checking %-50s${NC}" "$pid..."

  enabled_services=$(gcloud services list --project="$pid" --format="value(config.name)" 2>/dev/null || true)

  # Check if apikeys.googleapis.com is enabled
  has_apikeys_api="no"
  if echo "$enabled_services" | grep -qx "apikeys.googleapis.com"; then
    has_apikeys_api="yes"
  fi
  ALL_PROJECTS_APIKEYS_ENABLED+=("$has_apikeys_api")

  matched=()
  for api in "${TARGET_APIS[@]}"; do
    if echo "$enabled_services" | grep -qx "$api"; then
      matched+=("$api")
    fi
  done

  if [[ ${#matched[@]} -gt 0 ]]; then
    local_tag=""
    if [[ "$has_apikeys_api" == "no" ]]; then
      local_tag=" ${RED}[apikeys API not enabled]${NC}"
    fi
    printf "\r  ${GREEN}✔${NC}  %-50s %s%b\n" "$pid" "${matched[*]}" "$local_tag"
    AI_PROJECTS+=("$pid")
    AI_PROJECTS_APIS+=("${matched[*]}")
    AI_PROJECTS_APIKEYS_ENABLED+=("$has_apikeys_api")
  else
    printf "\r  ${DIM}  %-50s skipped${NC}\n" "$pid"
  fi
done

echo ""
if [[ ${#AI_PROJECTS[@]} -eq 0 ]]; then
  ok "No projects have AI APIs enabled. Nothing more to audit."
  exit 0
fi

ok "${BOLD}${#AI_PROJECTS[@]}${NC} project(s) have AI APIs enabled"

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 3: Audit API keys in AI-enabled projects
# ─────────────────────────────────────────────────────────────────────────────
header 3 "Auditing API keys in AI-enabled projects"

# Accumulators for summary
declare -a UNRESTRICTED_KEYS=()
declare -a AI_ALLOWED_KEYS=()
TOTAL_KEYS=0

declare -a UNTRUSTED_AI_PROJECTS=()

for _idx in "${!AI_PROJECTS[@]}"; do
  pid="${AI_PROJECTS[$_idx]}"
  apikeys_enabled="${AI_PROJECTS_APIKEYS_ENABLED[$_idx]}"
  divider
  printf "  ${BOLD}Project: ${CYAN}%s${NC}\n" "$pid"
  printf "  Enabled AI APIs: %s\n" "${AI_PROJECTS_APIS[$_idx]}"
  if [[ "$apikeys_enabled" == "yes" ]]; then
    printf "  API Keys API:    ${GREEN}enabled${NC} — ${GREEN}[TRUSTED]${NC}\n"
  else
    printf "  API Keys API:    ${RED}not enabled${NC} — ${YELLOW}[NEEDS MANUAL REVIEW]${NC}\n"
    UNTRUSTED_AI_PROJECTS+=("$pid")
  fi
  echo ""

  # List all API key resource names
  KEY_NAMES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && KEY_NAMES+=("$line")
  done < <(gcloud api-keys list --project="$pid" --format="value(name)" 2>/dev/null || true)

  if [[ ${#KEY_NAMES[@]} -eq 0 ]]; then
    info "No API keys found in this project."
    echo ""
    continue
  fi

  info "Found ${#KEY_NAMES[@]} API key(s)"
  TOTAL_KEYS=$((TOTAL_KEYS + ${#KEY_NAMES[@]}))

  for key_name in "${KEY_NAMES[@]}"; do
    # Describe the key to get restriction details (JSON output for parsing)
    key_json=$(gcloud api-keys describe "$key_name" --format=json 2>/dev/null || true)

    if [[ -z "$key_json" ]]; then
      warn "Could not describe key: $key_name"
      continue
    fi

    display_name=$(echo "$key_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('displayName','(unnamed)'))" 2>/dev/null)
    uid=$(echo "$key_json" | python3 -c "import sys,json; print(d.get('uid','?') if (d:=json.load(sys.stdin)) else '?')" 2>/dev/null)
    key_string=$(echo "$key_json" | python3 -c "import sys,json; print(d.get('keyString','n/a') if (d:=json.load(sys.stdin)) else 'n/a')" 2>/dev/null)
    create_time=$(echo "$key_json" | python3 -c "import sys,json; print(d.get('createTime','?') if (d:=json.load(sys.stdin)) else '?')" 2>/dev/null)

    # Check API restrictions
    has_api_restrictions=$(echo "$key_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('restrictions', {})
targets = r.get('apiTargets', [])
print('yes' if targets else 'no')
" 2>/dev/null)

    allowed_apis=$(echo "$key_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('restrictions', {})
targets = r.get('apiTargets', [])
apis = [t.get('service','') for t in targets]
print('\n'.join(apis) if apis else '')
" 2>/dev/null)

    # Determine key status
    is_unrestricted=false
    grants_ai_api=false
    matched_ai_apis=()

    if [[ "$has_api_restrictions" == "no" ]]; then
      is_unrestricted=true
    fi

    for api in "${TARGET_APIS[@]}"; do
      if echo "$allowed_apis" | grep -qx "$api"; then
        grants_ai_api=true
        matched_ai_apis+=("$api")
      fi
    done

    # Print key details
    echo ""
    if $is_unrestricted; then
      alert "${BOLD}Key: ${display_name}${NC}  ${RED}[UNRESTRICTED]${NC}"
      UNRESTRICTED_KEYS+=("${pid} | ${display_name} | ${key_name}")
    elif $grants_ai_api; then
      warn "${BOLD}Key: ${display_name}${NC}  ${YELLOW}[AI API ACCESS]${NC}"
    else
      ok "${BOLD}Key: ${display_name}${NC}"
    fi

    bullet "UID:     $uid"
    bullet "Created: $create_time"
    if [[ "$key_string" != "n/a" ]]; then
      masked="${key_string:0:8}...${key_string: -4}"
      bullet "Key:     $masked"
    fi

    if $is_unrestricted; then
      bullet "${RED}API restrictions: NONE (key can call ANY enabled API)${NC}"
      # An unrestricted key implicitly grants AI API access too
      AI_ALLOWED_KEYS+=("${pid} | ${display_name} | UNRESTRICTED (all APIs) | ${key_name}")
    elif [[ -n "$allowed_apis" ]]; then
      bullet "Allowed APIs:"
      while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if [[ " ${TARGET_APIS[*]} " == *" $svc "* ]]; then
          printf "        ${YELLOW}→ %s${NC}\n" "$svc"
        else
          printf "          %s\n" "$svc"
        fi
      done <<< "$allowed_apis"

      if $grants_ai_api; then
        AI_ALLOWED_KEYS+=("${pid} | ${display_name} | ${matched_ai_apis[*]} | ${key_name}")
      fi
    fi
  done
  echo ""
done

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 4: Scan API keys in remaining projects (no AI APIs enabled)
# ─────────────────────────────────────────────────────────────────────────────
header 4 "Scanning API keys in remaining projects (AI APIs not enabled)"

# Build list of non-AI projects with their apikeys API status
NON_AI_PROJECTS=()
NON_AI_PROJECTS_APIKEYS_ENABLED=()
for _idx in "${!PROJECT_IDS[@]}"; do
  pid="${PROJECT_IDS[$_idx]}"
  is_ai=false
  for ai_pid in "${AI_PROJECTS[@]}"; do
    if [[ "$pid" == "$ai_pid" ]]; then
      is_ai=true
      break
    fi
  done
  if ! $is_ai; then
    NON_AI_PROJECTS+=("$pid")
    NON_AI_PROJECTS_APIKEYS_ENABLED+=("${ALL_PROJECTS_APIKEYS_ENABLED[$_idx]}")
  fi
done

info "Scanning ${#NON_AI_PROJECTS[@]} remaining projects for unrestricted API keys"
echo ""

declare -a OTHER_UNRESTRICTED_KEYS=()
declare -a UNTRUSTED_OTHER_PROJECTS=()
OTHER_TOTAL_KEYS=0

for _idx in "${!NON_AI_PROJECTS[@]}"; do
  pid="${NON_AI_PROJECTS[$_idx]}"
  apikeys_enabled="${NON_AI_PROJECTS_APIKEYS_ENABLED[$_idx]}"

  printf "  ${DIM}Checking %-50s${NC}" "$pid..."

  KEY_NAMES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && KEY_NAMES+=("$line")
  done < <(gcloud api-keys list --project="$pid" --format="value(name)" 2>/dev/null || true)

  trust_tag=""
  if [[ "$apikeys_enabled" == "no" ]]; then
    trust_tag=" ${YELLOW}[NEEDS MANUAL REVIEW]${NC}"
    UNTRUSTED_OTHER_PROJECTS+=("$pid")
  fi

  if [[ ${#KEY_NAMES[@]} -eq 0 ]]; then
    printf "\r  ${DIM}  %-50s no keys%b${NC}\n" "$pid" "$trust_tag"
    continue
  fi

  OTHER_TOTAL_KEYS=$((OTHER_TOTAL_KEYS + ${#KEY_NAMES[@]}))
  proj_unrestricted=0

  for key_name in "${KEY_NAMES[@]}"; do
    key_json=$(gcloud api-keys describe "$key_name" --format=json 2>/dev/null || true)
    [[ -z "$key_json" ]] && continue

    display_name=$(echo "$key_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('displayName','(unnamed)'))" 2>/dev/null)

    has_api_restrictions=$(echo "$key_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('restrictions', {})
targets = r.get('apiTargets', [])
print('yes' if targets else 'no')
" 2>/dev/null)

    if [[ "$has_api_restrictions" == "no" ]]; then
      proj_unrestricted=$((proj_unrestricted + 1))
      OTHER_UNRESTRICTED_KEYS+=("${pid} | ${display_name} | ${key_name}")
    fi
  done

  if [[ $proj_unrestricted -gt 0 ]]; then
    printf "\r  ${RED}✘${NC}  %-50s %d key(s), ${RED}%d unrestricted${NC}%b\n" "$pid" "${#KEY_NAMES[@]}" "$proj_unrestricted" "$trust_tag"
  else
    printf "\r  ${GREEN}✔${NC}  %-50s %d key(s), all restricted%b\n" "$pid" "${#KEY_NAMES[@]}" "$trust_tag"
  fi
done

echo ""
TOTAL_KEYS=$((TOTAL_KEYS + OTHER_TOTAL_KEYS))

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo ""
divider
printf "${BOLD}${BLUE}  SUMMARY${NC}\n"
divider
echo ""

TOTAL_UNTRUSTED=$((${#UNTRUSTED_AI_PROJECTS[@]} + ${#UNTRUSTED_OTHER_PROJECTS[@]}))

info "Total projects scanned:        ${#PROJECT_IDS[@]}"
info "Projects with AI APIs enabled: ${#AI_PROJECTS[@]}"
info "Projects without AI APIs:      ${#NON_AI_PROJECTS[@]}"
info "Total API keys inspected:      ${TOTAL_KEYS}"
echo ""

# Trust status
if [[ $TOTAL_UNTRUSTED -gt 0 ]]; then
  warn "${YELLOW}Projects without apikeys.googleapis.com enabled: ${TOTAL_UNTRUSTED}${NC}"
  info "These projects may have API keys not visible to gcloud."
  info "Results for these projects are tagged ${YELLOW}[NEEDS MANUAL REVIEW]${NC}."
  info "Review them in GCP Console: APIs & Services > Credentials."
  if [[ ${#UNTRUSTED_AI_PROJECTS[@]} -gt 0 ]]; then
    printf "      ${YELLOW}AI-enabled projects:${NC}\n"
    for p in "${UNTRUSTED_AI_PROJECTS[@]}"; do
      printf "        ${YELLOW}•${NC} %s\n" "$p"
    done
  fi
  if [[ ${#UNTRUSTED_OTHER_PROJECTS[@]} -gt 0 ]]; then
    printf "      ${YELLOW}Other projects:${NC}\n"
    for p in "${UNTRUSTED_OTHER_PROJECTS[@]}"; do
      printf "        ${YELLOW}•${NC} %s\n" "$p"
    done
  fi
else
  ok "All projects have apikeys.googleapis.com enabled — results are ${GREEN}[TRUSTED]${NC}."
fi
echo ""

# 3a) Unrestricted keys in AI-enabled projects
printf "  ${BOLD}AI-enabled projects (Stage 3):${NC}\n"
if [[ ${#UNRESTRICTED_KEYS[@]} -gt 0 ]]; then
  alert "${RED}Unrestricted API keys: ${#UNRESTRICTED_KEYS[@]}${NC}"
  for entry in "${UNRESTRICTED_KEYS[@]}"; do
    IFS='|' read -r proj name resource <<< "$entry"
    printf "      ${RED}•${NC} Project: %-30s Key: %s\n" "$(echo "$proj" | xargs)" "$(echo "$name" | xargs)"
  done
else
  ok "No unrestricted API keys found."
fi

# 3b) Keys with AI API access
if [[ ${#AI_ALLOWED_KEYS[@]} -gt 0 ]]; then
  warn "${YELLOW}Keys with AI API access: ${#AI_ALLOWED_KEYS[@]}${NC}"
  for entry in "${AI_ALLOWED_KEYS[@]}"; do
    IFS='|' read -r proj name apis resource <<< "$entry"
    printf "      ${YELLOW}•${NC} Project: %-30s Key: %-25s APIs: %s\n" \
      "$(echo "$proj" | xargs)" "$(echo "$name" | xargs)" "$(echo "$apis" | xargs)"
  done
else
  ok "No API keys explicitly grant AI API access."
fi
echo ""

# 4) Unrestricted keys in remaining projects
printf "  ${BOLD}Remaining projects (Stage 4):${NC}\n"
info "API keys inspected:            ${OTHER_TOTAL_KEYS}"
if [[ ${#OTHER_UNRESTRICTED_KEYS[@]} -gt 0 ]]; then
  alert "${RED}Unrestricted API keys: ${#OTHER_UNRESTRICTED_KEYS[@]}${NC}"
  for entry in "${OTHER_UNRESTRICTED_KEYS[@]}"; do
    IFS='|' read -r proj name resource <<< "$entry"
    printf "      ${RED}•${NC} Project: %-30s Key: %s\n" "$(echo "$proj" | xargs)" "$(echo "$name" | xargs)"
  done
else
  ok "No unrestricted API keys found."
fi
echo ""

divider
echo ""
