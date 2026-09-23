#!/usr/bin/env bash
set -Eeuo pipefail

# pip installs podman-compose in /usr/local/bin on Oracle Linux, which is not
# always included in the PATH used by cloud-init.
export PATH="/usr/local/bin:${PATH}"

ROOT="/opt/utilities-livestack"
SOURCE_DIR="${ROOT}/application"
RUNTIME_ENV="${ROOT}/runtime-bootstrap.env"
WALLET_ARCHIVE="${ROOT}/wallet.zip"
WALLET_DIR="${ROOT}/wallet"
COMPOSE_FILE="${ROOT}/compose.resource-manager.yml"
APP_ENV_FILE="${ROOT}/utilities.env"
ADB_BOOTSTRAP_ERROR_FILE="${ROOT}/adb-bootstrap.err"
STATUS_FILE="${ROOT}/deployment-status.txt"
API_PRIVATE_KEY_FILE="${ROOT}/selectai-api-key.pem"
API_PUBLIC_KEY_FILE="${ROOT}/selectai-api-key-public.pem"
BOOTSTRAP_PHASE="initializing"
BOOTSTRAP_TERMINAL_STATE=""
INSTANCE_OCID=""
LOCAL_API_KEY_FINGERPRINT=""
OCI_API_KEY_FINGERPRINT=""

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

write_deployment_status() {
  local state="$1"
  local phase="$2"
  local marker="$3"
  local exit_code="${4:-}"
  local error_class="${5:-}"
  local error_code="${6:-}"
  local error_step="${7:-}"

  # The status file intentionally contains no credentials or bootstrap-log
  # details. Resource Manager reads it through a dedicated Object Storage PAR.
  install -d -m 0700 "${ROOT}" 2>/dev/null || return 0
  {
    printf 'format=utilities-rm-bootstrap/v1\n'
    printf 'state=%s\n' "${state}"
    printf 'phase=%s\n' "${phase}"
    printf 'deployment_id=%s\n' "${DEPLOYMENT_ID:-unknown}"
    printf 'instance_ocid=%s\n' "${INSTANCE_OCID:-unknown}"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'marker=%s\n' "${marker}"
    if [[ -n "${exit_code}" ]]; then
      printf 'exit_code=%s\n' "${exit_code}"
    fi
    if [[ "${state}" == "FAILED" && -n "${error_class}" ]]; then
      printf 'error_class=%s\n' "${error_class}"
    fi
    if [[ "${state}" == "FAILED" && "${error_code}" =~ ^(ORA|PLS|SP2)-[0-9]{4,5}$ ]]; then
      printf 'error_code=%s\n' "${error_code}"
    fi
    if [[ "${state}" == "FAILED" && "${error_step}" =~ ^[A-Za-z0-9_.-]{1,128}$ ]]; then
      printf 'error_step=%s\n' "${error_step}"
    fi
    if [[ "${state}" == "SUCCEEDED" ]]; then
      printf 'application=Use the application_url Resource Manager output.\n'
      printf 'health=http://127.0.0.1:%s/api/health\n' "${APPLICATION_PORT}"
      printf 'database_service=%s\n' "${ADB_SERVICE_NAME:-unknown}"
      printf 'database_user=APP_USER\n'
      printf 'select_ai_profile=%s\n' "${SELECT_AI_PROFILE:-unknown}"
      printf 'oci_genai_region=%s\n' "${OCI_GENAI_REGION:-unknown}"
      printf 'oci_genai_model=%s\n' "${OCI_GENAI_MODEL:-unknown}"
    fi
  } > "${STATUS_FILE}" || return 0
  chmod 0600 "${STATUS_FILE}" || true
  publish_deployment_status || true
}

publish_deployment_status() {
  [[ -n "${BOOTSTRAP_STATUS_UPLOAD_URL:-}" ]] || return 0
  [[ -f "${STATUS_FILE}" ]] || return 0

  if curl --fail --silent --show-error --retry 8 --retry-delay 5 \
    --connect-timeout 10 --max-time 30 --upload-file "${STATUS_FILE}" \
    "${BOOTSTRAP_STATUS_UPLOAD_URL}" >/dev/null; then
    return 0
  fi

  # The local status and bootstrap log remain available through SSH. The
  # Resource Manager waiter will report a clear timeout if this callback cannot
  # be delivered.
  log "WARNING: Unable to publish the bootstrap status callback."
  return 0
}

set_bootstrap_phase() {
  BOOTSTRAP_PHASE="$1"
  write_deployment_status "RUNNING" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_RUNNING"
}

cleanup_sensitive_runtime() {
  rm -f \
    "${ROOT}/application.zip" \
    "${WALLET_ARCHIVE}" \
    "${WALLET_ARCHIVE}.b64" \
    "${RUNTIME_ENV}" \
    "${API_PRIVATE_KEY_FILE}" \
    "${API_PUBLIC_KEY_FILE}" 2>/dev/null || true
  unset \
    ADB_ADMIN_PASSWORD \
    APPLICATION_PASSWORD \
    WALLET_PASSWORD \
    MODEL_OBJECT_URI \
    OCI_API_KEY_FINGERPRINT \
    LOCAL_API_KEY_FINGERPRINT || true
}

last_bootstrap_error_code() {
  [[ -f "${ADB_BOOTSTRAP_ERROR_FILE}" ]] || return 0
  grep -Eo '(ORA|PLS|SP2)-[0-9]{4,5}' "${ADB_BOOTSTRAP_ERROR_FILE}" 2>/dev/null |
    tail -n 1 || true
}

last_bootstrap_error_class() {
  local phase_marker
  [[ -f "${ADB_BOOTSTRAP_ERROR_FILE}" ]] || { printf '%s' 'bootstrap_failure'; return 0; }
  phase_marker="$(grep -Eo 'UTILITIES_SQL_PHASE=[A-Z0-9_]+' "${ADB_BOOTSTRAP_ERROR_FILE}" 2>/dev/null | tail -n 1 | cut -d= -f2)"
  if [[ -n "${phase_marker}" ]]; then
    printf 'sqlcl_phase_%s' "$(printf '%s' "${phase_marker}" | tr '[:upper:]' '[:lower:]')"
  else
    printf '%s' 'bootstrap_failure'
  fi
}

last_bootstrap_error_step() {
  [[ -f "${ADB_BOOTSTRAP_ERROR_FILE}" ]] || return 0
  grep -Eo 'UTILITIES_SQL_STEP=[A-Za-z0-9_.-]+' "${ADB_BOOTSTRAP_ERROR_FILE}" 2>/dev/null |
    tail -n 1 | cut -d= -f2 || true
}

fail() {
  log "FAILED: $*"
  write_deployment_status "FAILED" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_FAILED" "1" "bootstrap_failure"
  cleanup_sensitive_runtime
  exit 1
}

on_unhandled_error() {
  local exit_code="$1"

  trap - ERR
  set +e
  if [[ "${BOOTSTRAP_TERMINAL_STATE}" != "SUCCEEDED" ]]; then
    local error_code="$(last_bootstrap_error_code)"
    local error_class="$(last_bootstrap_error_class)"
    local error_step="$(last_bootstrap_error_step)"
    log "FAILED: Bootstrap exited during ${BOOTSTRAP_PHASE} (exit code ${exit_code})."
    write_deployment_status "FAILED" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_FAILED" "${exit_code}" "${error_class}" "${error_code}" "${error_step}"
    cleanup_sensitive_runtime
  fi
  exit "${exit_code}"
}

on_termination_signal() {
  local signal_name="$1"
  local exit_code="$2"

  trap - ERR INT TERM
  set +e
  if [[ "${BOOTSTRAP_TERMINAL_STATE}" != "SUCCEEDED" ]]; then
    log "FAILED: Bootstrap received ${signal_name} during ${BOOTSTRAP_PHASE}."
    write_deployment_status "FAILED" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_INTERRUPTED" "${exit_code}" "bootstrap_interrupted"
    cleanup_sensitive_runtime
  fi
  exit "${exit_code}"
}

trap 'on_unhandled_error "$?"' ERR
trap 'on_termination_signal INT 130' INT
trap 'on_termination_signal TERM 143' TERM

decode() {
  printf '%s' "$1" | base64 --decode
}

resolve_instance_ocid() {
  local attempt
  local response

  # IMDSv2 can briefly be unavailable during the earliest cloud-init stages.
  # Retry before declaring bootstrap failed; legacy IMDS is intentionally
  # disabled on this instance.
  for attempt in {1..6}; do
    response="$(curl -fsS -H 'Authorization: Bearer Oracle' \
      http://169.254.169.254/opc/v2/instance/ 2>/dev/null || true)"
    INSTANCE_OCID="$(printf '%s' "${response}" \
      | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1)"
    if [[ -n "${INSTANCE_OCID}" && "${INSTANCE_OCID}" == ocid1.instance.* ]]; then
      return 0
    fi
    sleep 2
  done

  fail "Unable to resolve this VM instance OCID from OCI instance metadata."
}

generate_and_publish_api_key() {
  local callback_file="${ROOT}/selectai-api-key-public-callback.json"
  local issued_at
  local public_key_b64

  command -v openssl >/dev/null 2>&1 || fail "OpenSSL is required to generate the Select AI API signing key."
  command -v jq >/dev/null 2>&1 || fail "jq is required to create the public-only key callback."

  rm -f "${API_PRIVATE_KEY_FILE}" "${API_PUBLIC_KEY_FILE}" "${callback_file}"
  openssl genpkey \
    -algorithm RSA \
    -pkeyopt rsa_keygen_bits:2048 \
    -out "${API_PRIVATE_KEY_FILE}" >/dev/null 2>&1
  openssl pkey \
    -in "${API_PRIVATE_KEY_FILE}" \
    -pubout \
    -out "${API_PUBLIC_KEY_FILE}" >/dev/null 2>&1
  chmod 0600 "${API_PRIVATE_KEY_FILE}" "${API_PUBLIC_KEY_FILE}"

  openssl pkey -in "${API_PRIVATE_KEY_FILE}" -noout -check >/dev/null 2>&1 ||
    fail "The generated Select AI private key failed local validation."
  openssl pkey -pubin -in "${API_PUBLIC_KEY_FILE}" -noout >/dev/null 2>&1 ||
    fail "The generated Select AI public key failed local validation."

  LOCAL_API_KEY_FINGERPRINT="$(
    openssl pkey -pubin -in "${API_PUBLIC_KEY_FILE}" -outform DER 2>/dev/null |
      openssl dgst -md5 -r |
      awk '{print $1}' |
      sed 's/../&:/g; s/:$//'
  )"
  [[ "${LOCAL_API_KEY_FINGERPRINT}" =~ ^([0-9a-f]{2}:){15}[0-9a-f]{2}$ ]] ||
    fail "Unable to calculate the local Select AI API-key fingerprint."

  public_key_b64="$(base64 --wrap=0 "${API_PUBLIC_KEY_FILE}")"
  issued_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg deployment_id "${DEPLOYMENT_ID}" \
    --arg instance_ocid "${INSTANCE_OCID}" \
    --arg issued_at "${issued_at}" \
    --arg public_key_b64 "${public_key_b64}" \
    '{
      format: "utilities-selectai-api-key-public/v1",
      state: "READY",
      deployment_id: $deployment_id,
      instance_ocid: $instance_ocid,
      issued_at: $issued_at,
      public_key_b64: $public_key_b64,
      marker: "SELECTAI_API_KEY_PUBLIC_READY"
    }' >"${callback_file}"
  chmod 0600 "${callback_file}"

  curl --fail --silent --show-error --retry 8 --retry-delay 3 \
    --connect-timeout 10 --max-time 30 \
    -H 'Content-Type: application/json' \
    --upload-file "${callback_file}" \
    "${API_KEY_PUBLIC_UPLOAD_URL}" >/dev/null
  rm -f "${callback_file}"
  log "Published the instance-bound public half of the Select AI API signing key."
}

wait_for_api_key_activation() {
  local activation
  local activated_at
  local activated_epoch
  local deadline
  local deployment_id
  local expires_at
  local expires_epoch
  local fingerprint
  local format
  local instance_ocid
  local marker
  local now
  local state

  deadline=$(( $(date -u +%s) + 1800 ))
  log "Waiting for Resource Manager to register the public key."

  while (( $(date -u +%s) < deadline )); do
    activation="$(
      curl --fail --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        -H 'Cache-Control: no-cache' \
        "${API_KEY_ACTIVATION_URL}" 2>/dev/null || true
    )"

    if [[ -n "${activation}" ]] && jq -e . >/dev/null 2>&1 <<<"${activation}"; then
      format="$(jq -r '.format // ""' <<<"${activation}")"
      state="$(jq -r '.state // ""' <<<"${activation}")"
      marker="$(jq -r '.marker // ""' <<<"${activation}")"
      deployment_id="$(jq -r '.deployment_id // ""' <<<"${activation}")"
      instance_ocid="$(jq -r '.instance_ocid // ""' <<<"${activation}")"
      fingerprint="$(jq -r '.fingerprint // ""' <<<"${activation}")"
      activated_at="$(jq -r '.activated_at // ""' <<<"${activation}")"
      expires_at="$(jq -r '.expires_at // ""' <<<"${activation}")"

      if [[
        "${format}" == "utilities-selectai-api-key-activation/v1" &&
          "${state}" == "ACTIVE" &&
          "${marker}" == "SELECTAI_API_KEY_ACTIVATED" &&
          "${deployment_id}" == "${DEPLOYMENT_ID}" &&
          "${instance_ocid}" == "${INSTANCE_OCID}"
      ]]; then
        [[ "${fingerprint}" =~ ^([0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}$ ]] ||
          fail "Resource Manager returned an invalid API-key fingerprint."
        [[ "${fingerprint,,}" == "${LOCAL_API_KEY_FINGERPRINT,,}" ]] ||
          fail "The registered OCI API-key fingerprint does not match the key generated by this VM."

        activated_epoch="$(date -u -d "${activated_at}" +%s 2>/dev/null || true)"
        expires_epoch="$(date -u -d "${expires_at}" +%s 2>/dev/null || true)"
        now="$(date -u +%s)"
        [[ "${activated_epoch}" =~ ^[0-9]+$ && "${expires_epoch}" =~ ^[0-9]+$ ]] ||
          fail "The API-key activation callback has invalid timestamps."
        (( activated_epoch <= now + 300 && now <= expires_epoch )) ||
          fail "The API-key activation callback is stale or expired."

        OCI_API_KEY_FINGERPRINT="${fingerprint,,}"
        export OCI_API_KEY_FINGERPRINT
        log "Verified the registered API key against the locally generated public key."
        return 0
      fi
    fi

    sleep 5
  done

  fail "Timed out waiting for Terraform to register and activate the Select AI API key."
}

run_compose() {
  if podman compose version >/dev/null 2>&1; then
    podman compose -f "${COMPOSE_FILE}" "$@"
  elif command -v podman-compose >/dev/null 2>&1; then
    podman-compose -f "${COMPOSE_FILE}" "$@"
  else
    python3 -m podman_compose -f "${COMPOSE_FILE}" "$@"
  fi
}

valid_adb_admin_password() {
  local password="$1"
  local password_lower

  [[ ${#password} -ge 12 && ${#password} -le 30 ]] || return 1
  [[ "${password}" =~ [[:upper:]] ]] || return 1
  [[ "${password}" =~ [[:lower:]] ]] || return 1
  [[ "${password}" =~ [[:digit:]] ]] || return 1
  [[ "${password}" != *[[:space:]]* ]] || return 1
  [[ "${password}" != *"'"* && "${password}" != *'"'* ]] || return 1
  password_lower="$(printf '%s' "${password}" | tr '[:upper:]' '[:lower:]')"
  [[ "${password_lower}" != *admin* ]] || return 1
}

[[ -f "${RUNTIME_ENV}" ]] || fail "Missing protected runtime configuration: ${RUNTIME_ENV}"

# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

APPLICATION_ARCHIVE_URL="$(decode "${APPLICATION_ARCHIVE_URL_B64}")"
WALLET_ARCHIVE_URL="$(decode "${WALLET_ARCHIVE_URL_B64}")"
BOOTSTRAP_STATUS_UPLOAD_URL="$(decode "${BOOTSTRAP_STATUS_UPLOAD_URL_B64}")"
API_KEY_PUBLIC_UPLOAD_URL="$(decode "${API_KEY_PUBLIC_UPLOAD_URL_B64}")"
API_KEY_ACTIVATION_URL="$(decode "${API_KEY_ACTIVATION_URL_B64}")"
ADB_ADMIN_PASSWORD="$(decode "${ADB_ADMIN_PASSWORD_B64}")"
APPLICATION_PASSWORD="$(decode "${APPLICATION_PASSWORD_B64}")"
WALLET_PASSWORD="$(decode "${WALLET_PASSWORD_B64}")"
ADB_SERVICE_NAME="$(decode "${ADB_SERVICE_NAME_B64}")"
MODEL_OBJECT_URI="$(decode "${MODEL_OBJECT_URI_B64}")"
OCI_TENANCY_OCID="$(decode "${OCI_TENANCY_OCID_B64}")"
OCI_USER_OCID="$(decode "${OCI_USER_OCID_B64}")"
OCI_COMPARTMENT_OCID="$(decode "${OCI_COMPARTMENT_OCID_B64}")"
OCI_GENAI_REGION="$(decode "${OCI_GENAI_REGION_B64}")"
OCI_GENAI_MODEL="$(decode "${OCI_GENAI_MODEL_B64}")"
SELECT_AI_PROFILE="$(decode "${SELECT_AI_PROFILE_B64}")"
SELECT_AI_PRIMARY_AGENT_TEAM="$(decode "${SELECT_AI_PRIMARY_AGENT_TEAM_B64}")"
SELECT_AI_AGENT_TEAMS="$(decode "${SELECT_AI_AGENT_TEAMS_B64}")"

resolve_instance_ocid
set_bootstrap_phase "runtime_configuration"
valid_adb_admin_password "${ADB_ADMIN_PASSWORD}" || fail "ADB ADMIN password is invalid. It must meet the Autonomous Database password requirements."
[[ "${APPLICATION_PASSWORD}" =~ ^[A-Za-z0-9]{12,30}$ ]] || fail "Generated APP_USER password is invalid."
[[ "${WALLET_PASSWORD}" =~ ^[A-Za-z0-9]{12,30}$ ]] || fail "Generated wallet password is invalid."
[[ "${ADB_SERVICE_NAME}" =~ ^[A-Za-z][A-Za-z0-9_]{0,63}$ ]] || fail "ADB service name is invalid."
[[ "${MODEL_OBJECT_URI}" == https://* ]] || fail "The Utilities embedding model URI must use HTTPS."
[[ "${MODEL_OBJECT_URI}" != *"'"* && "${MODEL_OBJECT_URI}" != *'"'* ]] || fail "The Utilities embedding model URI contains an unsupported quote."
[[ "${BOOTSTRAP_STATUS_UPLOAD_URL}" == https://* ]] || fail "The bootstrap status callback URI must use HTTPS."
[[ "${API_KEY_PUBLIC_UPLOAD_URL}" == https://* ]] || fail "The public-key callback URI must use HTTPS."
[[ "${API_KEY_ACTIVATION_URL}" == https://* ]] || fail "The API-key activation callback URI must use HTTPS."
[[ "${DEPLOYMENT_ID}" =~ ^[0-9a-f]{8}$ ]] || fail "The deployment binding is invalid."
[[ "${OCI_TENANCY_OCID}" == ocid1.tenancy.* ]] || fail "The Resource Manager tenancy OCID is invalid."
[[ "${OCI_USER_OCID}" == ocid1.user.* ]] || fail "The Resource Manager current-user OCID is invalid."
[[ "${OCI_COMPARTMENT_OCID}" == ocid1.compartment.* || "${OCI_COMPARTMENT_OCID}" == ocid1.tenancy.* ]] ||
  fail "The OCI Generative AI compartment OCID is invalid."
case "${OCI_GENAI_REGION}" in
  ap-hyderabad-1 | ap-osaka-1 | eu-frankfurt-1 | me-riyadh-1 | sa-saopaulo-1 | uk-london-1 | us-chicago-1) ;;
  *) fail "The selected OCI Generative AI region does not offer Cohere Command A in on-demand mode." ;;
esac
[[ "${OCI_GENAI_MODEL}" == "cohere.command-a-03-2025" ]] || fail "The OCI Generative AI model is unsupported."
[[ "${SELECT_AI_PROFILE}" =~ ^[A-Z][A-Z0-9_]{0,127}$ ]] || fail "The Select AI profile name is invalid."
[[ "${SELECT_AI_PRIMARY_AGENT_TEAM}" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
  fail "The primary Select AI agent-team name is invalid."
[[ "${SELECT_AI_AGENT_TEAMS}" =~ ^[A-Z][A-Z0-9_]*(,[A-Z][A-Z0-9_]*)*$ ]] ||
  fail "The Select AI agent-team list is invalid."
[[ ",${SELECT_AI_AGENT_TEAMS}," == *",${SELECT_AI_PRIMARY_AGENT_TEAM},"* ]] ||
  fail "The primary Select AI agent team is not present in the configured team list."

umask 077
install -d -m 0700 "${ROOT}" "${SOURCE_DIR}" "${WALLET_DIR}"

set_bootstrap_phase "runtime_prerequisites"
log "Installing Resource Manager runtime prerequisites."
# Ksplice is not needed for this disposable application VM.  Its regional
# repository can be unreachable from a new public subnet, so exclude it from
# the bootstrap transaction instead of failing the deployment before callback
# publication.
dnf config-manager --set-disabled ol9_ksplice >/dev/null 2>&1 || true

# The regional OCI yum endpoint can briefly refuse a fresh VM connection while
# cloud-init is starting.  This is a transport failure, not a package conflict;
# retry the whole transaction with a clean metadata cache before failing the
# deployment.  Keeping the retry here also guarantees that the bound API-key
# callback is not awaited until the VM has had a fair chance to bootstrap.
dnf_install_with_retry() {
  local attempt=1
  local max_attempts=8
  until dnf -y --setopt=retries=5 --setopt=timeout=30 install "$@"; do
    if (( attempt >= max_attempts )); then
      return 1
    fi
    log "dnf install attempt ${attempt}/${max_attempts} failed; clearing metadata and retrying in 15 seconds."
    dnf clean all >/dev/null 2>&1 || true
    rm -rf /var/cache/dnf/*
    sleep 15
    ((attempt++))
  done
}

# `sqlcl` is not an OL9 RPM. Java 17 is the supported OL9 runtime; SQLcl comes
# from one immutable Oracle release URL with its matching pinned SHA-256.
# Never combine a digest with the moving `sqlcl-latest.zip` alias.
dnf_install_with_retry container-tools java-17-openjdk-headless curl jq openssl unzip python3 python3-pip

install_sqlcl() {
  local sqlcl_url='https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-26.2.2.233.1901.zip'
  local sqlcl_sha256='17f89fddf69722f37d7bde0718e66490647b25b295bf52fba92ba0ad042fa256'
  local sqlcl_archive='/tmp/sqlcl-26.2.2.233.1901.zip'
  local sqlcl_install_root='/opt/oracle'
  local sqlcl_binary

  curl --fail --location --proto '=https' --tlsv1.2 --retry 8 --retry-delay 5 \
    --connect-timeout 30 "${sqlcl_url}" -o "${sqlcl_archive}"
  printf '%s  %s\n' "${sqlcl_sha256}" "${sqlcl_archive}" | sha256sum --check --status ||
    fail 'SQLcl download digest did not match the pinned release.'
  install -d -m 0755 "${sqlcl_install_root}"
  unzip -q -o "${sqlcl_archive}" -d "${sqlcl_install_root}"
  sqlcl_binary="$(find "${sqlcl_install_root}" -type f -path '*/bin/sql' -print -quit)"
  [[ -n "${sqlcl_binary}" ]] || fail 'Oracle SQLcl archive did not contain the sql command.'
  ln -sfn "${sqlcl_binary}" /usr/local/bin/sql
  rm -f -- "${sqlcl_archive}"
  command -v java >/dev/null 2>&1 || fail 'Java 17 installation did not provide java.'
}

install_sqlcl

if ! podman compose version >/dev/null 2>&1 && ! command -v podman-compose >/dev/null 2>&1; then
  # OL9's enabled repositories do not ship a podman-compose RPM.  Install the
  # supported Python wrapper directly instead of misclassifying the expected
  # "No match for argument" response as a transient repository failure.
  python3 -m pip install --upgrade 'podman-compose>=1.2,<2'
fi

command -v sql >/dev/null 2>&1 || fail "SQLcl installation did not provide the sql command."

set_bootstrap_phase "selectai_api_key_exchange"
generate_and_publish_api_key
wait_for_api_key_activation

set_bootstrap_phase "application_download"
log "Downloading the Utilities application bundled with this Resource Manager stack."
curl -fsSL --retry 8 --retry-delay 5 "${APPLICATION_ARCHIVE_URL}" -o "${ROOT}/application.zip"
rm -rf "${SOURCE_DIR}"
install -d -m 0700 "${SOURCE_DIR}"
unzip -q "${ROOT}/application.zip" -d "${SOURCE_DIR}"

set_bootstrap_phase "wallet_download"
log "Downloading the generated Autonomous Database wallet."
curl -fsSL --retry 8 --retry-delay 5 "${WALLET_ARCHIVE_URL}" -o "${WALLET_ARCHIVE}.b64"
base64 --decode "${WALLET_ARCHIVE}.b64" > "${WALLET_ARCHIVE}"
[[ -s "${WALLET_ARCHIVE}" ]] || fail "Generated Autonomous Database wallet is empty."
unzip -oq "${WALLET_ARCHIVE}" -d "${WALLET_DIR}"
if [[ -f "${WALLET_DIR}/ojdbc.properties" ]]; then
  escaped_wallet_dir="$(printf '%s' "${WALLET_DIR}" | sed 's#[\\/&]#\\&#g')"
  sed -i "s#/wallet#${escaped_wallet_dir}#g" "${WALLET_DIR}/ojdbc.properties"
fi
chmod -R go-rwx "${WALLET_DIR}"

cat > "${APP_ENV_FILE}" <<EOF
NODE_ENV=production
PORT=3001
# The frontend and API are served by the same Express application, so no
# instance public-IP discovery is required during first boot.
FRONTEND_URL=http://localhost:${APPLICATION_PORT}
ORACLE_USER=APP_USER
APP_SCHEMA_PASSWORD=${APPLICATION_PASSWORD}
ORACLE_CONNECTION_STRING=${ADB_SERVICE_NAME}
ORACLE_WALLET_LOCATION=/opt/oracle/wallet
ORACLE_WALLET_PASSWORD=${WALLET_PASSWORD}
ORACLE_CLIENT_MODE=thin
ORACLE_POOL_MIN=2
ORACLE_POOL_MAX=10
ORACLE_POOL_INCREMENT=1
SELECT_AI_PROFILE=${SELECT_AI_PROFILE}
NATIVE_SELECT_AI_ENABLED=true
OCI_GENAI_REGION=${OCI_GENAI_REGION}
OCI_GENAI_MODEL=${OCI_GENAI_MODEL}
SELECT_AI_PRIMARY_AGENT_TEAM=${SELECT_AI_PRIMARY_AGENT_TEAM}
SELECT_AI_AGENT_TEAMS=${SELECT_AI_AGENT_TEAMS}
SELECT_AI_CALL_TIMEOUT_MS=180000
SELECT_AI_AGENT_CALL_TIMEOUT_MS=300000
SELECT_AI_AGENT_STATE_CALL_TIMEOUT_MS=30000
DEMO_USAGE_COUNTER_ENABLED=false
EOF
chmod 0600 "${APP_ENV_FILE}"

cat > "${COMPOSE_FILE}" <<EOF
services:
  app:
    build:
      context: ${SOURCE_DIR}
      dockerfile: Containerfile
    image: utilities-livestack:resource-manager
    container_name: utilities-application
    env_file:
      - ${APP_ENV_FILE}
    ports:
      - "${APPLICATION_PORT}:3001"
    volumes:
      - ${WALLET_DIR}:/opt/oracle/wallet:ro,Z
    healthcheck:
      test: ["CMD-SHELL", "node -e \"require('http').get('http://127.0.0.1:3001/api/health', (res) => process.exit(res.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))\""]
      interval: 15s
      timeout: 5s
      retries: 40
      start_period: 180s
    networks:
      - utilities
    restart: unless-stopped

networks:
  utilities:
    name: utilities-livestack
EOF
chmod 0600 "${COMPOSE_FILE}"

set_bootstrap_phase "database_bootstrap"
log "Creating APP_USER, loading the Utilities schema and data, and validating ADB."
export ADB_CONNECT_STRING="${ADB_SERVICE_NAME}"
export ADB_ADMIN_PASSWORD
export APP_SCHEMA_PASSWORD="${APPLICATION_PASSWORD}"
export WALLET_ARCHIVE
export MODEL_OBJECT_URI
export UTILITIES_SOURCE_DIR="${SOURCE_DIR}"
export OCI_TENANCY_OCID
export OCI_USER_OCID
export OCI_COMPARTMENT_OCID
export OCI_GENAI_REGION
export OCI_GENAI_MODEL_ID="${OCI_GENAI_MODEL}"
export OCI_API_KEY_FINGERPRINT
export OCI_API_PRIVATE_KEY_FILE="${API_PRIVATE_KEY_FILE}"
rm -f "${ADB_BOOTSTRAP_ERROR_FILE}"
bash "${SOURCE_DIR}/deployment/bootstrap-utilities-adb.sh" 2>"${ADB_BOOTSTRAP_ERROR_FILE}"
rm -f "${API_PRIVATE_KEY_FILE}" "${API_PUBLIC_KEY_FILE}"
unset LOCAL_API_KEY_FINGERPRINT OCI_API_KEY_FINGERPRINT OCI_API_PRIVATE_KEY_FILE

systemctl enable --now podman.socket || true
systemctl enable podman-restart.service || true

if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${APPLICATION_PORT}/tcp"
  firewall-cmd --reload
fi

set_bootstrap_phase "application_build"
log "Building and starting the Utilities application."
run_compose up -d --build app
set_bootstrap_phase "application_health_check"
for attempt in $(seq 1 180); do
  if curl --noproxy '*' -fsS "http://127.0.0.1:${APPLICATION_PORT}/api/health" >/dev/null; then
    break
  fi
  [[ "${attempt}" == "180" ]] && fail "The database-backed Utilities health check did not pass."
  sleep 5
done

cleanup_sensitive_runtime
write_deployment_status "SUCCEEDED" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_OK"
BOOTSTRAP_TERMINAL_STATE="SUCCEEDED"
log "RESOURCE_MANAGER_DEPLOYMENT_OK"
