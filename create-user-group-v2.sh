#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Hitachi VSP Configuration Manager (v1) - Tenant bootstrap
# v2: Summary + confirmation before creating user group/user
# - Create user-group (async job) + wait
# - Create user (async job) + wait
# - List resource groups dynamically
# ============================================================

# -------------------------
# Requirements check
# -------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command '$1' not found in PATH." >&2
    exit 1
  }
}

need_cmd curl
need_cmd jq
need_cmd base64

# -------------------------
# Prompt helpers
# -------------------------
prompt() {
  local __var="$1" __msg="$2" __default="${3:-}"
  if [[ -n "$__default" ]]; then
    read -r -p "$__msg [$__default]: " "$__var"
    eval "$__var=\${$__var:-$__default}"
  else
    read -r -p "$__msg: " "$__var"
  fi
}

prompt_secret() {
  local __var="$1" __msg="$2"
  read -r -s -p "$__msg: " "$__var"
  echo
}

# -------------------------
# Auth header builder (Basic)
# -------------------------
build_auth_header() {
  local user="$1" pass="$2"
  local token
  token="$(printf "%s:%s" "$user" "$pass" | base64 | tr -d '\n')"
  echo "Authorization: Basic $token"
}

# -------------------------
# Generic API call: returns response body; exits on non-2xx
# Accepts 200/201/202 etc.
# -------------------------
api_call() {
  local method="$1" url="$2" auth_header="$3" data="${4:-}"
  local tmp_body tmp_headers http_code

  tmp_body="$(mktemp)"
  tmp_headers="$(mktemp)"

  if [[ -n "$data" ]]; then
    http_code="$(
      curl -k -sS -X "$method" "$url" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "$auth_header" \
        --data "$data" \
        -D "$tmp_headers" \
        -o "$tmp_body" \
        -w "%{http_code}"
    )"
  else
    http_code="$(
      curl -k -sS -X "$method" "$url" \
        -H "Accept: application/json" \
        -H "$auth_header" \
        -D "$tmp_headers" \
        -o "$tmp_body" \
        -w "%{http_code}"
    )"
  fi

  if [[ ! "$http_code" =~ ^2 ]]; then
    echo "ERROR: API call failed: $method $url (HTTP $http_code)" >&2
    echo "---- Response headers ----" >&2
    sed 's/\r$//' "$tmp_headers" >&2
    echo "---- Response body ----" >&2
    cat "$tmp_body" >&2
    rm -f "$tmp_body" "$tmp_headers"
    exit 1
  fi

  cat "$tmp_body"
  rm -f "$tmp_body" "$tmp_headers"
}

# -------------------------
# Convert "3,5, 7" -> JSON array of integers [3,5,7]
# Exits if any element is not a number.
# -------------------------
csv_ids_to_json_int_array() {
  local csv="$1"
  jq -n --arg csv "$csv" '
    ($csv
      | gsub("[[:space:]]+";"")
      | split(",")
      | map(select(length>0))
    ) as $arr
    | ( $arr | map(tonumber) )  # tonumber will error if non-numeric
  '
}

# -------------------------
# Pretty print resource groups from various possible response shapes
# (Adjust fields here if your array uses different names.)
# -------------------------
print_resource_groups() {
  local json="$1"
  echo
  echo "Available Resource Groups"
  echo "---------------------------------------------------------------------"
  printf "%-10s %-30s %-30s\n" "RG_ID" "NAME" "DESCRIPTION"
  echo "---------------------------------------------------------------------"

  echo "$json" | jq -r '
    # Try common containers: resourceGroups / data / items / root array
    (.resourceGroups? // .data? // .items? // .) as $rg
    | (if ($rg|type)=="array" then $rg else [] end)
    | .[]
    | [
        (.resourceGroupId // .id // .resourceGroupNo // "N/A"),
        (.resourceGroupName // .name // "N/A"),
        (.description // .comment // "N/A")
      ]
    | @tsv
  ' | while IFS=$'\t' read -r id name desc; do
      printf "%-10s %-30s %-30s\n" "$id" "$name" "$desc"
    done

  echo "---------------------------------------------------------------------"
  echo
}

# -------------------------
# Job polling (per your semantics)
# status: Initializing | Running | Completed
# state : Succeeded | Failed
# Success: status=Completed AND state=Succeeded
# Failure: state=Failed OR (status=Completed AND state!=Succeeded)
# -------------------------
wait_for_job() {
  local base_url="$1" auth_header="$2" job_id="$3"
  local interval="${4:-10}"   # seconds
  local timeout="${5:-600}"   # seconds

  local url="${base_url}/objects/jobs/${job_id}"
  local start now elapsed job_json status state

  start="$(date +%s)"
  echo "Waiting for job ${job_id} (poll=${interval}s, timeout=${timeout}s)..."

  while true; do
    job_json="$(api_call "GET" "$url" "$auth_header")"
    status="$(echo "$job_json" | jq -r '.status // empty')"
    state="$(echo "$job_json" | jq -r '.state // empty')"

    echo "  Job ${job_id}: status='${status}', state='${state}'"

    # Fail fast
    if [[ "$state" == "Failed" ]]; then
      echo "ERROR: Job ${job_id} FAILED." >&2
      echo "$job_json" | jq . >&2
      return 1
    fi

    # Success
    if [[ "$status" == "Completed" && "$state" == "Succeeded" ]]; then
      echo "Job ${job_id} completed successfully."
      return 0
    fi

    # Completed but not succeeded -> treat as failure
    if [[ "$status" == "Completed" && "$state" != "Succeeded" ]]; then
      echo "ERROR: Job ${job_id} completed but did not succeed (state='${state}')." >&2
      echo "$job_json" | jq . >&2
      return 1
    fi

    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= timeout )); then
      echo "ERROR: Timed out waiting for job ${job_id} after ${timeout}s." >&2
      echo "Last job payload:" >&2
      echo "$job_json" | jq . >&2
      return 1
    fi

    sleep "$interval"
  done
}

# Extract jobId from POST response
get_job_id() {
  local json="$1"
  echo "$json" | jq -r '.jobId // empty'
}

# POST + wait for job completion
post_and_wait_job() {
  local base_url="$1" auth_header="$2" post_url="$3" payload="$4"
  local interval="${5:-10}" timeout="${6:-600}"

  local resp job_id
  resp="$(api_call "POST" "$post_url" "$auth_header" "$payload")"

  # Show response without leaking secrets (your jobs already mask password as ****)
  echo "POST response:"
  echo "$resp" | jq .

  job_id="$(get_job_id "$resp")"
  if [[ -z "$job_id" ]]; then
    echo "ERROR: No jobId returned from POST response. Cannot poll async status." >&2
    echo "Response was:" >&2
    echo "$resp" | jq . >&2
    return 1
  fi

  wait_for_job "$base_url" "$auth_header" "$job_id" "$interval" "$timeout"
}

# ============================================================
# Main
# ============================================================
echo "Hitachi VSP Configuration Manager - Create User Group + User (v2)"
echo "======================================================================="
echo

# ---- Inputs
prompt STORAGE "Storage mgmt IP or FQDN" "192.168.176.64"
BASE_URL="https://${STORAGE}/ConfigurationManager/v1"

prompt ADMIN_USER "Admin username" "maintenance"
prompt_secret ADMIN_PASS "Admin password"
AUTH_HEADER="$(build_auth_header "$ADMIN_USER" "$ADMIN_PASS")"

prompt USERGROUP_ID "New userGroupId (e.g. tenant-a-usergroup)"
prompt USER_ID "New userId (e.g. tenant-b-user)"
prompt_secret USER_PASS "New user password (local auth)"

# ---- Roles (defaults as per your example)
DEFAULT_ROLES=(
  "Storage Administrator (Initial Configuration)"
  "Storage Administrator (Local Copy)"
  "Storage Administrator (Performance Management)"
  "Storage Administrator (Provisioning)"
  "Storage Administrator (Remote Copy)"
  "Storage Administrator (System Resource Management)"
)

echo
echo "Default roles:"
printf '  - %s\n' "${DEFAULT_ROLES[@]}"
echo
read -r -p "Use default roles? (Y/n): " use_default_roles
use_default_roles="${use_default_roles:-Y}"

if [[ "$use_default_roles" =~ ^[Yy]$ ]]; then
  ROLES_JSON="$(printf '%s\n' "${DEFAULT_ROLES[@]}" | jq -R . | jq -s .)"
else
  echo "Enter role names separated by commas (must match CM role names exactly)."
  read -r -p "Roles: " roles_csv
  ROLES_JSON="$(jq -n --arg csv "$roles_csv" '
    $csv
    | split(",")
    | map(gsub("^[[:space:]]+|[[:space:]]+$";""))
    | map(select(length>0))
  ')"
fi

# ---- Get & show resource groups
echo
echo "Fetching resource groups from: ${BASE_URL}/objects/resource-groups"
RG_JSON="$(api_call "GET" "${BASE_URL}/objects/resource-groups" "$AUTH_HEADER")"
print_resource_groups "$RG_JSON"

read -r -p "Enter resourceGroupIds to assign (comma-separated, e.g. 3,5): " rg_ids_csv
RG_IDS_JSON="$(csv_ids_to_json_int_array "$rg_ids_csv")"

# ---- Build user-group payload
UG_PAYLOAD="$(jq -n \
  --arg userGroupId "$USERGROUP_ID" \
  --argjson roleNames "$ROLES_JSON" \
  --argjson resourceGroupIds "$RG_IDS_JSON" \
  '{
    userGroupId: $userGroupId,
    roleNames: $roleNames,
    resourceGroupIds: $resourceGroupIds,
    hasAllResourceGroup: false
  }'
)"

# ---- Build user payload (prepared for review; not submitted until confirmed)
USER_PAYLOAD="$(jq -n \
  --arg userId "$USER_ID" \
  --arg userPassword "$USER_PASS" \
  --arg userGroupId "$USERGROUP_ID" \
  '{
    userId: $userId,
    authentication: "local",
    userPassword: $userPassword,
    userGroupNames: [ $userGroupId ]
  }'
)"

# ---- Summary and confirmation before any changes
echo
echo "======================================================================="
echo "Summary — review before proceeding"
echo "======================================================================="
echo "Storage:           ${STORAGE}"
echo "API base URL:      ${BASE_URL}"
echo "Admin user:        ${ADMIN_USER}"
echo
echo "New user group ID: ${USERGROUP_ID}"
echo "New user ID:       ${USER_ID}"
echo "User auth:         local"
echo "User password:     ********"
echo
echo "Roles:"
echo "$ROLES_JSON" | jq -r '.[]' | sed 's/^/  - /'
echo
echo "Resource group IDs:"
echo "$RG_IDS_JSON" | jq -r '.[]' | sed 's/^/  - /'
echo "======================================================================="
echo
read -r -p "Proceed with user group and user creation? (y/N): " confirm_proceed
confirm_proceed="${confirm_proceed:-N}"
if [[ ! "$confirm_proceed" =~ ^[Yy]$ ]]; then
  echo "Aborted. No changes were made."
  exit 0
fi

# ---- Create user-group (async job) & wait
echo
echo "Creating user group '${USERGROUP_ID}' (async)..."
post_and_wait_job "$BASE_URL" "$AUTH_HEADER" "${BASE_URL}/objects/user-groups" "$UG_PAYLOAD" 10 600

# ---- Confirm and print created user group (requested)
echo
echo "Created User Group details:"
api_call "GET" "${BASE_URL}/objects/user-groups/${USERGROUP_ID}" "$AUTH_HEADER" | jq .

# ---- Create user (async job) & wait
echo
echo "Creating user '${USER_ID}' in group '${USERGROUP_ID}' (async)..."
post_and_wait_job "$BASE_URL" "$AUTH_HEADER" "${BASE_URL}/objects/users" "$USER_PAYLOAD" 10 600

# ---- Optional: print user details
echo
echo "Created User details:"
api_call "GET" "${BASE_URL}/objects/users/${USER_ID}" "$AUTH_HEADER" | jq .

echo
echo "DONE."
