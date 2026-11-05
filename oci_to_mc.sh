#!/usr/bin/env bash
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
#
# OCI CLI -> Google Cloud Migration Center Exporter (2 Decoupled Milestones)
#   Milestone 1 (collect): Runs read-only OCI CLI commands across ALL subscribed
#                          OCI regions (or --regions list) with preflight config
#                          verification, selectable collection type (full,
#                          inventory, compute-only, metrics-only), verbose
#                          step-by-step telemetry, 4-layer timeout/retry
#                          handling, and per-compartment resume checkpoints.
#   Milestone 2 (export):  Converts local JSONL snapshot 100% offline via jq into
#                          Migration Center manual import CSVs (vmInfo.csv,
#                          diskInfo.csv, perfInfo.csv, tagInfo.csv) with schema
#                          validation, optional --anonymize, and <95 MiB splitting.

set -euo pipefail
export LC_ALL=C
trap '' HUP

MODE="run"
if [[ $# -gt 0 && "${1:-}" != -* ]]; then
  MODE="$1"
  shift
fi

COMP_ID=""
REGION=""
REGIONS_ARG=""
CUR_REGION=""
TENANCY_ID=""
TARGET_REGIONS=()
AUTH_MODE=""
CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
COLLECT_TYPE=""
VERBOSE=1
TRACE_CMDS=0
DAYS=30
RESOLUTION="1h"
CONN_TIMEOUT=15
READ_TIMEOUT=90
CMD_TIMEOUT=180
RETRIES=3
BACKOFF_BASE=2
MAX_METRIC_TIMEOUTS=2
RAW_DIR="./oci_raw_snapshot"
OUT_DIR="./mc_export_csv"
MAX_MB=95
MAX_BYTES=""
RESUME=0
ANONYMIZE=0
ANON_SALT="oci2mc-v1"
FALLBACK_REGION=""

usage() {
  cat <<'EOF'
Usage:
  ./oci_to_mc.sh [run|preflight|regions|collect|export] [options]

Modes:
  run         Run preflight + Milestone 1 (collect) + Milestone 2 (export) [default]
  preflight   Verify OCI CLI installation, config/key files, auth mode, and IAM read access
  regions     List subscribed OCI regions with instance/compartment counts (via OCI Search)
  collect     Milestone 1: Extract OCI inventory & MQL metrics via OCI CLI into JSONL snapshot
  export      Milestone 2: Offline conversion of JSONL snapshot into Migration Center CSVs

Collection Types (-t, --collect-type):
  full          (1) Complete: VMs + OS + VNICs + Boot/Block Volumes + 8 MQL Metrics [default]
  inventory     (2) Inventory Only (Fast): VMs + OS + VNICs + Volumes + Tags (skips slow MQL metrics)
  compute-only  (3) Ultra-Fast: Only VMs + Shapes + Tags + OS Images (skips VNICs, Volumes & MQL)
  metrics-only  (4) Metrics Only: Runs 8 MQL queries ONLY on compartments that already have VMs in --raw-dir

Options:
  -c, --compartment-ocid <OCID>  Root Compartment or Tenancy OCID (auto-detected from config/Cloud Shell if omitted)
  -t, --collect-type <TYPE>      Collection scope: full | inventory | compute-only | metrics-only (or 1|2|3|4)
  -v, --verbose                  Verbose mode with full OCI CLI command trace and elapsed timers
  -q, --quiet                    Quiet mode (only summary and error messages)
  --regions <all|r1,r2,...>      Regions to collect (default: all subscribed regions), e.g. sa-saopaulo-1,sa-vinhedo-1
  --region <REGION>              Single-region shortcut (same as --regions <REGION>)
  --auth <MODE>                  api_key | security_token | instance_obo_user | instance_principal | resource_principal
  --config-file <PATH>           OCI CLI config path (default: ~/.oci/config or $OCI_CLI_CONFIG_FILE)
  --profile <NAME>               OCI CLI config profile (default: DEFAULT or $OCI_CLI_PROFILE)
  --days <INT>                   Monitoring lookback window in days (default: 30)
  --resolution <1m|5m|1h>        MQL metric interval/resolution (default: 1h)
  --conn-timeout <SEC>           OCI CLI --connection-timeout in seconds (default: 15)
  --read-timeout <SEC>           OCI CLI --read-timeout in seconds (default: 90)
  --cmd-timeout <SEC>            OS watchdog timeout per OCI CLI process in seconds (default: 180)
  --retries <INT>                Max attempts on timeout/transient errors (default: 3)
  --backoff-base <SEC>           Exponential backoff base seconds (default: 2)
  --max-metric-timeouts <INT>    Circuit breaker: skip remaining MQL queries in a compartment after N consecutive metric timeouts (default: 2)
  --raw-dir <DIR>                Snapshot directory for Milestone 1 (default: ./oci_raw_snapshot)
  --out-dir <DIR>                Output CSV directory for Milestone 2 (default: ./mc_export_csv)
  --max-mb <INT>                 Max MiB per CSV before header-preserving split (default: 95; MC hard limit is 100 MB)
  --max-bytes <INT>              Optional byte-level override for CSV split threshold
  --resume                       Skip compartments already completed without errors in --raw-dir
  --anonymize                    Deterministically mask IDs, hostnames, IPs, and MACs via SHA-256
  --anonymize-salt <STR>         Custom salt for --anonymize
  -h, --help                     Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--compartment-ocid)    COMP_ID="${2:-}"; shift 2 ;;
    -t|--collect-type)        COLLECT_TYPE="${2:-}"; shift 2 ;;
    -v|--verbose)             VERBOSE=1; TRACE_CMDS=1; shift ;;
    -q|--quiet)               VERBOSE=0; TRACE_CMDS=0; shift ;;
    --region)                 REGION="${2:-}"; shift 2 ;;
    --regions)                REGIONS_ARG="${2:-}"; shift 2 ;;
    --auth)                   AUTH_MODE="${2:-}"; shift 2 ;;
    --config-file)            CONFIG_FILE="${2:-}"; shift 2 ;;
    --profile)                PROFILE="${2:-}"; shift 2 ;;
    --days)                   DAYS="${2:-}"; shift 2 ;;
    --resolution)             RESOLUTION="${2:-}"; shift 2 ;;
    --conn-timeout)           CONN_TIMEOUT="${2:-}"; shift 2 ;;
    --read-timeout)           READ_TIMEOUT="${2:-}"; shift 2 ;;
    --cmd-timeout)            CMD_TIMEOUT="${2:-}"; shift 2 ;;
    --retries)                RETRIES="${2:-}"; shift 2 ;;
    --backoff-base)           BACKOFF_BASE="${2:-}"; shift 2 ;;
    --max-metric-timeouts)    MAX_METRIC_TIMEOUTS="${2:-}"; shift 2 ;;
    --raw-dir)                RAW_DIR="${2:-}"; shift 2 ;;
    --out-dir)                OUT_DIR="${2:-}"; shift 2 ;;
    --max-mb)                 MAX_MB="${2:-}"; shift 2 ;;
    --max-bytes)              MAX_BYTES="${2:-}"; shift 2 ;;
    --resume)                 RESUME=1; shift ;;
    --anonymize)              ANONYMIZE=1; shift ;;
    --anonymize-salt)         ANON_SALT="${2:-}"; shift 2 ;;
    -h|--help)                usage; exit 0 ;;
    *) echo "[FATAL] Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in
  run|preflight|regions|collect|export) ;;
  *) echo "[FATAL] Invalid mode '$MODE'. Expected: run | preflight | regions | collect | export" >&2; exit 2 ;;
esac

TMP_WORK="$(mktemp -d)"
COMP_ERR_FLAG="$TMP_WORK/comp_had_error"
LAST_CALL_TIMED_OUT="$TMP_WORK/last_call_timed_out"
cleanup() { rm -rf "$TMP_WORK"; }
trap cleanup EXIT

ts_now()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log_info() { echo "[$(ts_now)] [INFO]  $*" >&2; }
log_verb() { [[ "$VERBOSE" -eq 1 ]] && echo "[$(ts_now)] [VERB]  $*" >&2 || true; }
log_cmd()  { [[ "$TRACE_CMDS" -eq 1 ]] && echo "[$(ts_now)] [TRACE] $*" >&2 || true; }
log_warn() { echo "[$(ts_now)] [WARN]  $*" >&2; }
log_error(){ echo "[$(ts_now)] [ERROR] $*" >&2; }
die()      { echo "[$(ts_now)] [FATAL] $*" >&2; exit 2; }

normalize_collect_type() {
  local raw="${1:-}"
  case "$raw" in
    1|full|FULL|all|ALL)                        COLLECT_TYPE="full" ;;
    2|inventory|INVENTORY|inv|no-metrics|fast)  COLLECT_TYPE="inventory" ;;
    3|compute-only|COMPUTE-ONLY|compute|vms)    COLLECT_TYPE="compute-only" ;;
    4|metrics-only|METRICS-ONLY|metrics|perf)   COLLECT_TYPE="metrics-only" ;;
    *)
      die "Invalid --collect-type '$raw'. Expected: full (1) | inventory (2) | compute-only (3) | metrics-only (4)"
      ;;
  esac
}

prompt_collect_type_if_needed() {
  if [[ -n "$COLLECT_TYPE" ]]; then
    normalize_collect_type "$COLLECT_TYPE"
    return 0
  fi

  # Interactive menu only when both stdin and stderr are attached to a live terminal
  # and not running inside automated non-interactive scripts
  if [[ -t 0 && -t 2 && -z "${TEST_STATE_DIR:-}" && "${CI:-}" != "true" ]]; then
    cat >&2 <<'EOF'
================================================================================
 Selecione o Tipo de Coleta OCI (--collect-type):
   [1] full         - Completa: VMs + SO + Rede (VNICs) + Discos + Métricas MQL (30d)
   [2] inventory    - Inventário Rápido (Sem Métricas): VMs + SO + Rede + Discos + Tags
                      (recomendado se o OCI Monitoring estiver dando timeout)
   [3] compute-only - Ultra-Rápida: Apenas VMs, Shapes, OCPUs, Memória, Tags e SO
   [4] metrics-only - Apenas Métricas MQL: Coleta CPU/Mem/IOPS/Rede somente nos
                      compartments que já possuem VMs salvas em --raw-dir
================================================================================
EOF
    printf 'Escolha o tipo de coleta [1-4, Enter=1 (full)]: ' >&2
    local choice=""
    if read -r -t 60 choice < /dev/tty 2>/dev/null || read -r choice 2>/dev/null; then
      choice="${choice:-1}"
      normalize_collect_type "$choice"
    else
      COLLECT_TYPE="full"
    fi
  else
    COLLECT_TYPE="full"
  fi
}

check_local_deps() {
  local missing=()
  for bin in jq timeout sha256sum awk sort; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required local utilities: ${missing[*]}. Install them via your OS package manager."
  fi
}

validate_window_params() {
  [[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -ge 1 ]] || die "--days must be a positive integer (got '$DAYS')."
  [[ "$RETRIES" =~ ^[0-9]+$ && "$RETRIES" -ge 1 ]] || die "--retries must be >= 1 (got '$RETRIES')."
  case "$RESOLUTION" in
    1m) [[ "$DAYS" -le 7 ]]  || die "--resolution 1m supports at most --days 7 in OCI Monitoring (got $DAYS)." ;;
    5m) [[ "$DAYS" -le 30 ]] || die "--resolution 5m supports at most --days 30 in OCI Monitoring (got $DAYS)." ;;
    1h) [[ "$DAYS" -le 90 ]] || die "--resolution 1h supports at most --days 90 in OCI Monitoring (got $DAYS)." ;;
    *)  die "--resolution must be one of: 1m, 5m, 1h (got '$RESOLUTION')." ;;
  esac
}

expand_home_path() {
  local p="$1"
  if [[ "$p" == "~/"* ]]; then
    printf '%s/%s' "$HOME" "${p#~/}"
  else
    printf '%s' "$p"
  fi
}

parse_ini_profile_key() {
  local file="$1" profile="$2" key="$3"
  awk -v prof="$profile" -v k="$key" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      line = $0
      sub(/^[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      in_prof = (line == prof)
      next
    }
    in_prof && $0 !~ /^[[:space:]]*(#|;|$)/ {
      pos = index($0, "=")
      if (pos > 0) {
        lhs = substr($0, 1, pos - 1)
        rhs = substr($0, pos + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        gsub(/\r$/, "", rhs)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
        if (lhs == k) { print rhs; exit }
      }
    }
  ' "$file"
}

has_ini_profile() {
  local file="$1" profile="$2"
  awk -v prof="$profile" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      line = $0
      sub(/^[[:space:]]*\[/, "", line)
      sub(/\][[:space:]]*$/, "", line)
      if (line == prof) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

record_oci_error() {
  local step="$1" comp_id="$2" rc="$3" attempts="$4" reason="$5" err_text="$6"
  [[ -d "$RAW_DIR" ]] || mkdir -p "$RAW_DIR"
  local clean_err
  clean_err="$(printf '%s' "$err_text" | LC_ALL=C tr -cd '\40-\176' | head -c 600)"
  jq -cn \
    --arg ts "$(ts_now)" \
    --arg cid "$comp_id" \
    --arg step "$step" \
    --argjson rc "${rc:-1}" \
    --argjson attempts "${attempts:-1}" \
    --arg reason "$reason" \
    --arg stderr "$clean_err" \
    --arg region "${CUR_REGION:-$REGION}" \
    '{timestamp:$ts, region:$region, compartment_id:$cid, step:$step, exit_code:$rc, attempts:$attempts, reason:$reason, stderr:$stderr}' \
    >> "$RAW_DIR/errors.jsonl" 2>/dev/null || true
}

# 4-Layer OCI CLI Execution Wrapper:
#   1) Native OCI CLI --connection-timeout, --read-timeout, --max-retries
#   2) OS-level process watchdog (timeout --kill-after=10s) catching hung sockets/pagination (rc 124/137/143)
#   3) Locale-safe exponential backoff retry loop + strict jq JSON validation
#   4) Structured error ledger ($RAW_DIR/errors.jsonl) + guaranteed non-fatal continuation
run_oci() {
  local step="$1" comp_id="$2" severity="$3"
  shift 3

  rm -f "$LAST_CALL_TIMED_OUT"

  local oci_args=(
    --output json
    --connection-timeout "$CONN_TIMEOUT"
    --read-timeout "$READ_TIMEOUT"
    --max-retries 3
    --auth "$AUTH_MODE"
  )
  if [[ "$AUTH_MODE" == "api_key" || "$AUTH_MODE" == "security_token" ]]; then
    oci_args+=(--config-file "$CONFIG_FILE" --profile "$PROFILE")
  fi
  local eff_region="${CUR_REGION:-$REGION}"
  if [[ -n "$eff_region" ]]; then
    oci_args+=(--region "$eff_region")
  fi

  local out_tmp="$TMP_WORK/oci_out_${BASHPID:-$$}_${RANDOM}.json"
  local err_tmp="$TMP_WORK/oci_err_${BASHPID:-$$}_${RANDOM}.log"
  local attempt=1 rc=0 reason="" is_transient=0 is_timeout=0 err_msg="" t0=0 elapsed=0

  while [[ "$attempt" -le "$RETRIES" ]]; do
    : > "$out_tmp"
    : > "$err_tmp"
    t0="$SECONDS"
    log_cmd "Executing [$step] [region=${eff_region:-default}] (attempt $attempt/$RETRIES, cmd-timeout=${CMD_TIMEOUT}s, read-timeout=${READ_TIMEOUT}s): oci ${oci_args[*]} $*"

    set +e
    OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True \
      timeout --kill-after=10s "${CMD_TIMEOUT}s" oci "${oci_args[@]}" "$@" < /dev/null >"$out_tmp" 2>"$err_tmp"
    rc=$?
    set -e
    elapsed=$(( SECONDS - t0 ))

    if [[ "$rc" -eq 0 ]]; then
      if [[ ! -s "$out_tmp" ]] || [[ -z "$(tr -d '[:space:]' < "$out_tmp")" ]]; then
        log_cmd "Completed [$step] in ${elapsed}s (empty output -> 0 items)."
        rm -f "$out_tmp" "$err_tmp"
        printf '{"data":[]}\n'
        return 0
      fi
      if jq -e . "$out_tmp" >/dev/null 2>&1; then
        log_cmd "Completed [$step] in ${elapsed}s (valid JSON)."
        cat "$out_tmp"
        rm -f "$out_tmp" "$err_tmp"
        return 0
      fi
      rc=65
      reason="INVALID_TRUNCATED_JSON"
      is_transient=1
      is_timeout=0
      err_msg="OCI CLI exited 0 but stdout was truncated or invalid JSON: $(head -c 300 "$out_tmp" | LC_ALL=C tr -cd '\40-\176')"
    else
      err_msg="$(tail -c 800 "$err_tmp" 2>/dev/null | LC_ALL=C tr -cd '\40-\176' || true)"
      if [[ "$rc" -eq 124 || "$rc" -eq 137 || "$rc" -eq 143 ]]; then
        reason="OS_WATCHDOG_TIMEOUT"
        is_transient=1
        is_timeout=1
      elif grep -Eqi 'ConnectTimeout|ReadTimeout|TimedOut|timed out|read operation timed out' "$err_tmp" 2>/dev/null; then
        reason="OCI_CLI_TIMEOUT"
        is_transient=1
        is_timeout=1
      elif grep -Eqi 'RequestException|ConnectionError|RemoteDisconnected|TooManyRequests|LimitExceeded|InternalError|ServiceUnavailable|"status":[[:space:]]*(429|500|502|503|504)' "$err_tmp" 2>/dev/null; then
        reason="OCI_TRANSIENT_ERROR"
        is_transient=1
        is_timeout=0
      else
        reason="OCI_CLI_ERROR"
        is_transient=0
        is_timeout=0
      fi
    fi

    if [[ "$is_transient" -eq 1 && "$attempt" -lt "$RETRIES" ]]; then
      local sleep_s=""
      if [[ "$BACKOFF_BASE" =~ ^[0-9]+$ ]]; then
        sleep_s="$(( BACKOFF_BASE * (1 << (attempt - 1)) ))"
      else
        sleep_s="$(LC_ALL=C awk -v b="$BACKOFF_BASE" -v a="$attempt" 'BEGIN { printf "%.2f", b * (2 ^ (a - 1)) }' 2>/dev/null || echo "1")"
      fi
      log_warn "Transient failure on '$step' (attempt $attempt/$RETRIES, reason=$reason, rc=$rc, elapsed=${elapsed}s). Retrying in ${sleep_s}s..."
      sleep "$sleep_s" 2>/dev/null || sleep 1
      attempt=$((attempt + 1))
      continue
    fi
    break
  done

  rm -f "$out_tmp" "$err_tmp"
  echo "1" > "$COMP_ERR_FLAG"
  if [[ "$is_timeout" -eq 1 ]]; then
    echo "1" > "$LAST_CALL_TIMED_OUT"
  fi
  record_oci_error "$step" "$comp_id" "$rc" "$attempt" "$reason" "$err_msg"

  if [[ "$severity" == "FATAL" ]]; then
    if [[ "$reason" == "OS_WATCHDOG_TIMEOUT" || "$reason" == "OCI_CLI_TIMEOUT" ]]; then
      log_error "OCI CLI timed out on '$step' after $attempt attempt(s) ($reason). Check network/VPN/proxy or raise --read-timeout / --cmd-timeout."
    elif printf '%s' "$err_msg" | grep -Eqi 'NotAuthenticated|"status":[[:space:]]*401'; then
      log_error "OCI CLI authentication failed (401 NotAuthenticated) on '$step'. Check API key/fingerprint or refresh session ('oci session authenticate')."
    elif printf '%s' "$err_msg" | grep -Eqi 'NotAuthorizedOrNotFound|"status":[[:space:]]*404'; then
      log_error "OCI CLI authorization/OCID check failed (404 NotAuthorizedOrNotFound) for '$comp_id'. Verify OCID and IAM read policy ('allow group <grp> to read all-resources in tenancy')."
    else
      log_error "Fatal OCI CLI error on '$step' (rc=$rc, reason=$reason): $err_msg"
    fi
    return 1
  fi

  log_error "Isolated failure on '$step' ($comp_id) after $attempt attempt(s): $reason (rc=$rc, elapsed=${elapsed}s). Logged to $RAW_DIR/errors.jsonl — CONTINUING collection!"
  printf '{"data":[]}\n'
  return 0
}

preflight_oci() {
  validate_window_params
  if ! command -v oci >/dev/null 2>&1; then
    die "OCI CLI ('oci') binary not found in PATH. Install OCI CLI or run inside OCI Cloud Shell."
  fi

  if [[ -z "$AUTH_MODE" ]]; then
    if [[ -n "${OCI_CLI_AUTH:-}" ]]; then
      AUTH_MODE="$OCI_CLI_AUTH"
    elif [[ "${OCI_CLI_CLOUD_SHELL:-}" =~ ^(True|true|1)$ ]]; then
      AUTH_MODE="instance_obo_user"
    else
      AUTH_MODE="api_key"
    fi
  fi

  case "$AUTH_MODE" in
    api_key|security_token)
      CONFIG_FILE="$(expand_home_path "$CONFIG_FILE")"
      [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || \
        die "OCI CLI config file not found or unreadable at '$CONFIG_FILE'. Run 'oci setup config' or 'oci session authenticate'."
      has_ini_profile "$CONFIG_FILE" "$PROFILE" || \
        die "Profile [$PROFILE] not found in '$CONFIG_FILE'. Check --profile or OCI_CLI_PROFILE."

      local cfg_tenancy cfg_region cfg_key cfg_user cfg_fp cfg_tok
      cfg_tenancy="$(parse_ini_profile_key "$CONFIG_FILE" "$PROFILE" "tenancy")"
      cfg_region="$(parse_ini_profile_key "$CONFIG_FILE" "$PROFILE" "region")"
      cfg_key="$(parse_ini_profile_key "$CONFIG_FILE" "$PROFILE" "key_file")"
      [[ -n "$cfg_tenancy" ]] || die "Missing 'tenancy' in [$PROFILE] of '$CONFIG_FILE'."
      [[ -n "$cfg_region" ]]  || die "Missing 'region' in [$PROFILE] of '$CONFIG_FILE'."
      [[ -n "$cfg_key" ]]     || die "Missing 'key_file' in [$PROFILE] of '$CONFIG_FILE'."

      cfg_key="$(expand_home_path "$cfg_key")"
      [[ -f "$cfg_key" && -r "$cfg_key" ]] || \
        die "Private key_file '$cfg_key' referenced in [$PROFILE] does not exist or is unreadable."

      local perm=""
      perm="$(stat -c '%a' "$cfg_key" 2>/dev/null || stat -f '%Lp' "$cfg_key" 2>/dev/null || true)"
      if [[ -n "$perm" && $(( 8#$perm & 8#077 )) -ne 0 ]]; then
        log_warn "Private key '$cfg_key' has open permissions ($perm). Recommended: chmod 600 '$cfg_key'."
      fi

      if [[ "$AUTH_MODE" == "api_key" ]]; then
        cfg_user="$(parse_ini_profile_key "$CONFIG_FILE" "$PROFILE" "user")"
        cfg_fp="$(parse_ini_profile_key "$CONFIG_FILE" "$PROFILE" "fingerprint")"
        [[ -n "$cfg_user" ]] || die "Missing 'user' in [$PROFILE] of '$CONFIG_FILE' for api_key auth."
        [[ -n "$cfg_fp" ]]   || die "Missing 'fingerprint' in [$PROFILE] of '$CONFIG_FILE' for api_key auth."
      else
        cfg_tok="$(parse_ini_profile_key "$CONFIG_FILE" "$PROFILE" "security_token_file")"
        [[ -n "$cfg_tok" ]] || die "Missing 'security_token_file' in [$PROFILE] of '$CONFIG_FILE' for security_token auth."
        cfg_tok="$(expand_home_path "$cfg_tok")"
        [[ -f "$cfg_tok" && -r "$cfg_tok" ]] || \
          die "Security token file '$cfg_tok' does not exist or is unreadable. Run 'oci session authenticate'."
      fi

      TENANCY_ID="$cfg_tenancy"
      [[ -n "$COMP_ID" ]] || COMP_ID="${OCI_TENANCY:-$cfg_tenancy}"
      FALLBACK_REGION="${REGION:-$cfg_region}"
      ;;
    instance_obo_user|instance_principal|resource_principal|oke_workload_identity)
      [[ -n "$COMP_ID" ]] || COMP_ID="${OCI_TENANCY:-}"
      [[ -n "$COMP_ID" ]] || die "--compartment-ocid <OCID> (or \$OCI_TENANCY) is required when using --auth $AUTH_MODE."
      FALLBACK_REGION="${REGION:-${OCI_REGION:-}}"
      TENANCY_ID="${OCI_TENANCY:-}"
      if [[ "$COMP_ID" == ocid1.tenancy.* ]]; then TENANCY_ID="$COMP_ID"; fi
      ;;
    *)
      die "Unsupported --auth mode '$AUTH_MODE'. Expected: api_key | security_token | instance_obo_user | instance_principal | resource_principal."
      ;;
  esac

  log_info "Verifying OCI CLI connectivity & IAM access (auth=$AUTH_MODE, region=${FALLBACK_REGION:-default}, target=$COMP_ID)..."
  if [[ "$COMP_ID" == ocid1.tenancy.* ]]; then
    run_oci "preflight:iam-tenancy-get" "$COMP_ID" FATAL \
      iam tenancy get --tenancy-id "$COMP_ID" >/dev/null
  else
    run_oci "preflight:iam-compartment-get" "$COMP_ID" FATAL \
      iam compartment get --compartment-id "$COMP_ID" >/dev/null
  fi
  log_info "OCI CLI preflight check PASSED."
}

discover_regions() {
  TARGET_REGIONS=()
  local req="$REGIONS_ARG"
  if [[ -z "$req" ]]; then
    if [[ -n "$REGION" ]]; then req="$REGION"; else req="all"; fi
  fi

  if [[ "$req" != "all" ]]; then
    local r _rs=()
    IFS=',' read -r -a _rs <<< "$req"
    for r in "${_rs[@]}"; do
      r="$(printf '%s' "$r" | tr -d '[:space:]')"
      [[ -n "$r" ]] && TARGET_REGIONS+=("$r")
    done
    [[ ${#TARGET_REGIONS[@]} -gt 0 ]] || die "--regions resolved to an empty list."
    log_info "Target OCI region(s) (user-selected): ${TARGET_REGIONS[*]}"
    return 0
  fi

  if [[ -z "$TENANCY_ID" ]]; then
    log_warn "Tenancy OCID unknown; cannot list subscribed regions. Falling back to '${FALLBACK_REGION:-default}'. Pass --regions <r1,r2> or export OCI_TENANCY."
    TARGET_REGIONS=("$FALLBACK_REGION")
    return 0
  fi

  log_info "Discovering subscribed OCI regions for tenancy $TENANCY_ID..."
  local rjson home
  rjson="$(run_oci "iam:region-subscription-list" "$TENANCY_ID" NONFATAL \
    iam region-subscription list --tenancy-id "$TENANCY_ID")"
  mapfile -t TARGET_REGIONS < <(printf '%s\n' "$rjson" \
    | jq -r '.data[]? | select((.status // "READY") == "READY") | .["region-name"] // empty' 2>/dev/null \
    | awk 'NF' | sort -u)
  if [[ ${#TARGET_REGIONS[@]} -eq 0 ]]; then
    log_warn "Could not list subscribed regions (see errors.jsonl). Falling back to '${FALLBACK_REGION:-default}'. Pass --regions <r1,r2> to override."
    TARGET_REGIONS=("$FALLBACK_REGION")
    return 0
  fi
  home="$(printf '%s\n' "$rjson" | jq -r '.data[]? | select(.["is-home-region"] == true) | .["region-name"] // empty' 2>/dev/null | head -n 1 || true)"
  log_info "Found ${#TARGET_REGIONS[@]} subscribed region(s): ${TARGET_REGIONS[*]} (home: ${home:-unknown})"
}

# Uses regional OCI Resource Search to list, in ONE call per region, the compartment
# of every non-terminated instance. Writes one compartment OCID per instance to $2.
# Returns 1 if the search call failed (caller falls back to a full compartment scan).
search_region_instances() {
  local r="$1" out_file="$2" sjson
  : > "$out_file"
  rm -f "$COMP_ERR_FLAG"
  CUR_REGION="$r"
  sjson="$(run_oci "search:instances:${r:-default}" "${TENANCY_ID:-$COMP_ID}" NONFATAL \
    search resource structured-search --query-text "query instance resources" --all)"
  if [[ -f "$COMP_ERR_FLAG" ]]; then
    rm -f "$COMP_ERR_FLAG"
    return 1
  fi
  # Only a well-formed {"data":{"items":[...]}} response is authoritative; anything else
  # (empty stdout, unexpected shape, truncated pagination) triggers a safe full-scan fallback.
  if ! printf '%s\n' "$sjson" | jq -e '(.data | type) == "object" and ((.data.items // null) | type) == "array" and (has("opc-next-page") | not)' >/dev/null 2>&1; then
    return 1
  fi
  printf '%s\n' "$sjson" | jq -r '
    .data.items[] |
    select(((.["lifecycle-state"] // "") | ascii_upcase) != "TERMINATED") |
    .["compartment-id"] // empty
  ' > "$out_file" 2>/dev/null || return 1
  return 0
}

report_regions() {
  preflight_oci
  discover_regions
  local r sfile n_inst n_comp
  sfile="$TMP_WORK/report_search.txt"
  printf '\n%-24s %-12s %-14s\n' "REGION" "INSTANCES" "COMPARTMENTS" >&2
  printf '%-24s %-12s %-14s\n' "------------------------" "------------" "--------------" >&2
  for r in "${TARGET_REGIONS[@]}"; do
    if search_region_instances "$r" "$sfile"; then
      n_inst="$(awk 'NF' "$sfile" | wc -l | tr -d ' ')"
      n_comp="$(awk 'NF' "$sfile" | sort -u | wc -l | tr -d ' ')"
      printf '%-24s %-12s %-14s\n' "${r:-default}" "$n_inst" "$n_comp" >&2
    else
      printf '%-24s %-12s %-14s\n' "${r:-default}" "ERROR" "search failed" >&2
    fi
  done
  CUR_REGION=""
  echo >&2
  log_info "Tip: collect only specific regions with --regions sa-saopaulo-1,sa-vinhedo-1 (default: all subscribed regions)."
}

collect_oci() {
  prompt_collect_type_if_needed
  preflight_oci

  log_info "Configuration: collect-type=$COLLECT_TYPE | regions=${REGIONS_ARG:-${REGION:-all}} | days=$DAYS | resolution=$RESOLUTION | conn-timeout=${CONN_TIMEOUT}s | read-timeout=${READ_TIMEOUT}s | cmd-timeout=${CMD_TIMEOUT}s | retries=$RETRIES"

  mkdir -p "$RAW_DIR/by_compartment" "$RAW_DIR/by_image"
  if [[ "$RESUME" -eq 0 && "$COLLECT_TYPE" != "metrics-only" ]]; then
    rm -rf "$RAW_DIR/by_compartment" "$RAW_DIR/by_image" "$RAW_DIR/.done_compartments" "$RAW_DIR/errors.jsonl"
    mkdir -p "$RAW_DIR/by_compartment" "$RAW_DIR/by_image"
  fi
  touch "$RAW_DIR/.done_compartments" "$RAW_DIR/errors.jsonl"

  local start_time end_time
  end_time="$(ts_now)"
  start_time="$(date -u -d "${DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-"${DAYS}"d +"%Y-%m-%dT%H:%M:%SZ")"

  local comp_names_file="$TMP_WORK/comp_names.tsv"
  : > "$comp_names_file"
  printf '%s\t%s\n' "$COMP_ID" "root" >> "$comp_names_file"

  discover_regions

  # Compartments are global (IAM): discover once, then fan out per region.
  local comp_list=()
  if [[ "$COLLECT_TYPE" == "metrics-only" ]]; then
    if [[ ! -s "$RAW_DIR/instances.jsonl" ]]; then
      die "--collect-type metrics-only requires an existing snapshot with instances in '$RAW_DIR/instances.jsonl'. Run '--collect-type inventory' first."
    fi
  else
    log_info "Milestone 1 (collect-type=$COLLECT_TYPE): Discovering active compartments under $COMP_ID..."
    comp_list=("$COMP_ID")
    if [[ "$COMP_ID" == ocid1.tenancy.* ]]; then
      local comp_json
      comp_json="$(run_oci "iam:compartment-list" "$COMP_ID" NONFATAL \
        iam compartment list --compartment-id "$COMP_ID" --compartment-id-in-subtree true --access-level ACCESSIBLE --lifecycle-state ACTIVE --all)"
      printf '%s\n' "$comp_json" | jq -r '.data[]? | select(.["lifecycle-state"] == "ACTIVE" or .["lifecycle-state"] == null) | [(.id // ""), (.name // "unnamed")] | @tsv' >> "$comp_names_file" 2>/dev/null || true
      while IFS= read -r cid; do
        [[ -n "$cid" ]] && comp_list+=("$cid")
      done < <(printf '%s\n' "$comp_json" | jq -r '.data[]? | select(.["lifecycle-state"] == "ACTIVE" or .["lifecycle-state"] == null) | .id // empty' 2>/dev/null || true)
    else
      local queue=("$COMP_ID") cur sub_json
      while [[ ${#queue[@]} -gt 0 ]]; do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        sub_json="$(run_oci "iam:compartment-list" "$cur" NONFATAL \
          iam compartment list --compartment-id "$cur" --lifecycle-state ACTIVE --all)"
        printf '%s\n' "$sub_json" | jq -r '.data[]? | select(.["lifecycle-state"] == "ACTIVE" or .["lifecycle-state"] == null) | [(.id // ""), (.name // "unnamed")] | @tsv' >> "$comp_names_file" 2>/dev/null || true
        while IFS= read -r cid; do
          if [[ -n "$cid" ]]; then
            comp_list+=("$cid")
            queue+=("$cid")
          fi
        done < <(printf '%s\n' "$sub_json" | jq -r '.data[]? | select(.["lifecycle-state"] == "ACTIVE" or .["lifecycle-state"] == null) | .id // empty' 2>/dev/null || true)
      done
    fi
    mapfile -t comp_list < <(printf '%s\n' "${comp_list[@]}" | awk 'NF && !seen[$0]++')
    log_info "Found ${#comp_list[@]} active compartment(s) (window: $start_time -> $end_time, resolution: $RESOLUTION)."
  fi

  # Build the (region|compartment) work list.
  local work_file="$TMP_WORK/work_items.txt" comps_sorted="$TMP_WORK/comps_sorted.txt"
  local sfile="$TMP_WORK/search_hits.txt" hits="$TMP_WORK/search_hits_in_scope.txt"
  : > "$work_file"
  printf '%s\n' "${comp_list[@]}" | awk 'NF' | sort -u > "$comps_sorted"
  local r rlabel n_hit
  for r in "${TARGET_REGIONS[@]}"; do
    rlabel="${r:-default}"
    if [[ "$COLLECT_TYPE" == "metrics-only" ]]; then
      jq -r --arg r "$r" --arg fb "$FALLBACK_REGION" '
        def rf: if . == null or . == "" then null elif . == "iad" then "us-ashburn-1" elif . == "phx" then "us-phoenix-1" else . end;
        select(((._oci_region // null) // (.region | rf) // $fb) == $r) | .["compartment-id"] // empty
      ' "$RAW_DIR/instances.jsonl" 2>/dev/null | awk 'NF' | sort -u | awk -v r="$r" '{ print r "|" $0 }' >> "$work_file"
      log_info "[region $rlabel] metrics-only: $(grep -c "^${r}|" "$work_file" || true) compartment(s) with VMs in snapshot."
      continue
    fi
    if search_region_instances "$r" "$sfile"; then
      awk 'NF' "$sfile" | sort -u | comm -12 - "$comps_sorted" > "$hits"
      n_hit="$(wc -l < "$hits" | tr -d ' ')"
      log_info "[region $rlabel] OCI Search: $(awk 'NF' "$sfile" | wc -l | tr -d ' ') instance(s) in $n_hit of ${#comp_list[@]} compartment(s) -> scanning only those."
      awk -v r="$r" 'NF { print r "|" $0 }' "$hits" >> "$work_file"
    else
      log_warn "[region $rlabel] OCI Search unavailable; falling back to full scan of ${#comp_list[@]} compartment(s) in this region (slower)."
      awk -v r="$r" 'NF { print r "|" $0 }' "$comps_sorted" >> "$work_file"
    fi
  done
  CUR_REGION=""

  local do_net_storage=1 do_metrics=1
  case "$COLLECT_TYPE" in
    full)         do_net_storage=1; do_metrics=1 ;;
    inventory)    do_net_storage=1; do_metrics=0 ;;
    compute-only) do_net_storage=0; do_metrics=0 ;;
    metrics-only) do_net_storage=0; do_metrics=1 ;;
  esac

  local mql_specs=(
    "cpu|oci_computeagent|CpuUtilization[${RESOLUTION}].groupBy(resourceId).mean()"
    "mem|oci_computeagent|MemoryUtilization[${RESOLUTION}].groupBy(resourceId).mean()"
    "disk_r|oci_computeagent|DiskIopsRead[${RESOLUTION}].groupBy(resourceId).rate()"
    "disk_w|oci_computeagent|DiskIopsWritten[${RESOLUTION}].groupBy(resourceId).rate()"
    "net_in|oci_computeagent|NetworksBytesIn[${RESOLUTION}].groupBy(resourceId).rate()"
    "net_out|oci_computeagent|NetworksBytesOut[${RESOLUTION}].groupBy(resourceId).rate()"
    "vol_r|oci_blockstore|VolumeReadOps[${RESOLUTION}].groupBy(resourceId).rate()"
    "vol_w|oci_blockstore|VolumeWriteOps[${RESOLUTION}].groupBy(resourceId).rate()"
  )

  local work_items=()
  mapfile -t work_items < "$work_file"
  local total_items="${#work_items[@]}"
  local item_idx=0 comps_with_vms=0 item key tag
  local cid cname chash cdir inst_json inst_count ad mspec mkey mns mquery mjson raw_json

  log_info "Collection plan: $total_items (region|compartment) work item(s) across ${#TARGET_REGIONS[@]} region(s)."

  for item in "${work_items[@]}"; do
    item_idx=$((item_idx + 1))
    r="${item%%|*}"
    cid="${item#*|}"
    rlabel="${r:-default}"
    key="${r}|${cid}"
    CUR_REGION="$r"
    cname="$(awk -F'\t' -v id="$cid" '$1 == id { print $2; exit }' "$comp_names_file" 2>/dev/null || true)"
    [[ -n "$cname" ]] || cname="compartment"
    tag="[$item_idx/$total_items] [$rlabel]"

    if [[ "$RESUME" -eq 1 ]] && grep -Fxq "$key" "$RAW_DIR/.done_compartments" 2>/dev/null; then
      log_info "$tag Skipping already completed compartment (--resume): $cname ($cid)"
      continue
    fi

    rm -f "$COMP_ERR_FLAG"
    if [[ -s "$RAW_DIR/errors.jsonl" ]]; then
      if jq -c --arg cid "$cid" --arg r "$r" 'select(.compartment_id != $cid or (.region // "") != $r)' "$RAW_DIR/errors.jsonl" > "$TMP_WORK/errors_filtered.jsonl" 2>/dev/null; then
        mv "$TMP_WORK/errors_filtered.jsonl" "$RAW_DIR/errors.jsonl"
      fi
    fi

    chash="$(printf '%s' "$key" | sha256sum | cut -c1-16)"
    cdir="$RAW_DIR/by_compartment/${rlabel}/$chash"

    if [[ "$COLLECT_TYPE" == "metrics-only" ]]; then
      mkdir -p "$cdir"
      if [[ ! -s "$cdir/instances.jsonl" ]]; then
        jq -c --arg cid "$cid" --arg r "$r" --arg fb "$FALLBACK_REGION" '
          def rf: if . == null or . == "" then null elif . == "iad" then "us-ashburn-1" elif . == "phx" then "us-phoenix-1" else . end;
          select(.["compartment-id"] == $cid and (((._oci_region // null) // (.region | rf) // $fb) == $r))
        ' "$RAW_DIR/instances.jsonl" > "$cdir/instances.jsonl" 2>/dev/null || true
      fi
      inst_count="$(wc -l < "$cdir/instances.jsonl" | tr -d ' ')"
      log_info "$tag Collecting MQL metrics for compartment: $cname ($cid) [$inst_count existing VM(s)]"
    else
      rm -rf "$cdir"
      mkdir -p "$cdir"
      log_info "$tag Collecting compartment: $cname ($cid)"

      inst_json="$(run_oci "compute:instance-list" "$cid" NONFATAL compute instance list --compartment-id "$cid" --all)"
      printf '%s\n' "$inst_json" | jq -c --arg r "$r" '.data[]? | select(.["lifecycle-state"] != "TERMINATED" and .["lifecycle-state"] != "TERMINATING") | . + {"_oci_region": $r}' > "$cdir/instances.jsonl" 2>/dev/null || : > "$cdir/instances.jsonl"
      inst_count="$(wc -l < "$cdir/instances.jsonl" | tr -d ' ')"
    fi

    if [[ "$inst_count" -gt 0 ]]; then
      comps_with_vms=$((comps_with_vms + 1))
      log_verb "$tag Found $inst_count active VM(s) in $cname. Collecting attached resources (collect-type=$COLLECT_TYPE)..."

      if [[ "$do_net_storage" -eq 1 ]]; then
        raw_json="$(run_oci "compute:vnic-attachment-list" "$cid" NONFATAL compute vnic-attachment list --compartment-id "$cid" --all)"
        printf '%s\n' "$raw_json" | jq -c '.data[]?' > "$cdir/vnic_attachments.jsonl" 2>/dev/null || : > "$cdir/vnic_attachments.jsonl"

        raw_json="$(run_oci "compute:instance-list-vnics" "$cid" NONFATAL compute instance list-vnics --compartment-id "$cid" --all)"
        printf '%s\n' "$raw_json" | jq -c '.data[]?' > "$cdir/vnics.jsonl" 2>/dev/null || : > "$cdir/vnics.jsonl"

        raw_json="$(run_oci "compute:volume-attachment-list" "$cid" NONFATAL compute volume-attachment list --compartment-id "$cid" --all)"
        printf '%s\n' "$raw_json" | jq -c '.data[]?' > "$cdir/volume_attachments.jsonl" 2>/dev/null || : > "$cdir/volume_attachments.jsonl"

        raw_json="$(run_oci "bv:volume-list" "$cid" NONFATAL bv volume list --compartment-id "$cid" --all)"
        printf '%s\n' "$raw_json" | jq -c '.data[]?' > "$cdir/volumes.jsonl" 2>/dev/null || : > "$cdir/volumes.jsonl"

        : > "$cdir/boot_volume_attachments.jsonl"
        : > "$cdir/boot_volumes.jsonl"
        while IFS= read -r ad; do
          [[ -n "$ad" ]] || continue
          raw_json="$(run_oci "compute:boot-volume-attachment-list:$ad" "$cid" NONFATAL \
            compute boot-volume-attachment list --compartment-id "$cid" --availability-domain "$ad" --all)"
          printf '%s\n' "$raw_json" | jq -c '.data[]?' >> "$cdir/boot_volume_attachments.jsonl" 2>/dev/null || true

          raw_json="$(run_oci "bv:boot-volume-list:$ad" "$cid" NONFATAL \
            bv boot-volume list --compartment-id "$cid" --availability-domain "$ad" --all)"
          printf '%s\n' "$raw_json" | jq -c '.data[]?' >> "$cdir/boot_volumes.jsonl" 2>/dev/null || true
        done < <(jq -r '.["availability-domain"] // empty' "$cdir/instances.jsonl" 2>/dev/null | sort -u)

        log_verb "$tag Storage & Network in $cname: vnics=$(wc -l < "$cdir/vnics.jsonl" | tr -d ' '), boot_vols=$(wc -l < "$cdir/boot_volumes.jsonl" | tr -d ' '), block_vols=$(wc -l < "$cdir/volumes.jsonl" | tr -d ' ')."
      elif [[ "$COLLECT_TYPE" != "metrics-only" ]]; then
        for empty_f in vnic_attachments vnics volume_attachments volumes boot_volume_attachments boot_volumes; do
          : > "$cdir/${empty_f}.jsonl"
        done
      fi

      if [[ "$do_metrics" -eq 1 ]]; then
        : > "$cdir/metrics.jsonl"
        local consec_metric_timeouts=0
        for mspec in "${mql_specs[@]}"; do
          IFS='|' read -r mkey mns mquery <<< "$mspec"
          if [[ "$MAX_METRIC_TIMEOUTS" -gt 0 && "$consec_metric_timeouts" -ge "$MAX_METRIC_TIMEOUTS" ]]; then
            log_warn "$tag Circuit breaker active: skipping 'monitoring:${mkey}' in $cname after $consec_metric_timeouts consecutive MQL timeouts."
            echo "1" > "$COMP_ERR_FLAG"
            record_oci_error "monitoring:${mkey}" "$cid" 124 0 "CIRCUIT_BREAKER_SKIPPED_AFTER_TIMEOUTS" "Skipped after $consec_metric_timeouts consecutive MQL timeouts in compartment"
            continue
          fi

          log_verb "$tag Querying MQL metric '${mkey}' ($mns) for $cname..."
          mjson="$(run_oci "monitoring:${mkey}" "$cid" NONFATAL \
            monitoring metric-data summarize-metrics-data \
            --compartment-id "$cid" \
            --namespace "$mns" \
            --query-text "$mquery" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --resolution "$RESOLUTION")"

          if [[ -f "$LAST_CALL_TIMED_OUT" ]]; then
            consec_metric_timeouts=$((consec_metric_timeouts + 1))
          else
            consec_metric_timeouts=0
          fi

          printf '%s\n' "$mjson" | jq -c --arg mk "$mkey" '
            .data[]? |
            ((.dimensions.resourceId // .dimensions.RESOURCEID // "") | tostring) as $rid |
            select($rid != "") |
            (.["aggregated-datapoints"] // [])[] |
            select(.value != null and .timestamp != null) |
            {metric_key: $mk, resource_id: $rid, timestamp: .timestamp, value: .value}
          ' >> "$cdir/metrics.jsonl" 2>/dev/null || true
        done
        log_verb "$tag MQL metrics in $cname: $(wc -l < "$cdir/metrics.jsonl" | tr -d ' ') datapoint(s) collected."
      else
        : > "$cdir/metrics.jsonl"
      fi
    else
      log_verb "$tag 0 active VMs in $cname (skipping VNIC, volume, and metric queries)."
      for empty_f in vnic_attachments vnics volume_attachments volumes boot_volume_attachments boot_volumes metrics; do
        [[ -f "$cdir/${empty_f}.jsonl" ]] || : > "$cdir/${empty_f}.jsonl"
      done
    fi

    if [[ ! -f "$COMP_ERR_FLAG" ]]; then
      if ! grep -Fxq "$key" "$RAW_DIR/.done_compartments" 2>/dev/null; then
        printf '%s\n' "$key" >> "$RAW_DIR/.done_compartments"
      fi
    else
      log_warn "$tag Compartment $cname ($cid) experienced isolated timeout/errors; left unmarked for '--resume' retry. Moving on..."
    fi
  done
  CUR_REGION=""

  for stream in instances vnic_attachments vnics volume_attachments volumes boot_volume_attachments boot_volumes metrics; do
    if [[ "$COLLECT_TYPE" == "metrics-only" && "$stream" != "metrics" && -s "$RAW_DIR/${stream}.jsonl" ]]; then
      continue
    fi
    : > "$RAW_DIR/${stream}.jsonl"
    for f in "$RAW_DIR"/by_compartment/*/*/"${stream}.jsonl"; do
      if [[ -f "$f" ]]; then
        cat "$f" >> "$RAW_DIR/${stream}.jsonl"
      fi
    done
  done

  if [[ "$COLLECT_TYPE" != "metrics-only" ]]; then
    : > "$RAW_DIR/images.jsonl"
    local img_pair img_r img_id ihash img_file img_json
    while IFS= read -r img_pair; do
      img_r="${img_pair%%|*}"
      img_id="${img_pair#*|}"
      [[ -n "$img_id" ]] || continue
      ihash="$(printf '%s|%s' "$img_r" "$img_id" | sha256sum | cut -c1-16)"
      img_file="$RAW_DIR/by_image/${ihash}.json"
      if [[ ! -s "$img_file" ]]; then
        rm -f "$COMP_ERR_FLAG"
        CUR_REGION="$img_r"
        log_verb "[${img_r:-default}] Inspecting OS image metadata: $img_id"
        img_json="$(run_oci "compute:image-get" "$img_id" NONFATAL compute image get --image-id "$img_id")"
        if [[ ! -f "$COMP_ERR_FLAG" ]]; then
          printf '%s\n' "$img_json" | jq -c '.data | select(type == "object" and (.id // "") != "")' > "$img_file" 2>/dev/null || rm -f "$img_file"
        fi
      fi
      if [[ -s "$img_file" ]]; then
        cat "$img_file" >> "$RAW_DIR/images.jsonl"
      fi
    done < <(jq -r '"\(._oci_region // "")|\(.["image-id"] // "")"' "$RAW_DIR/instances.jsonl" 2>/dev/null | sort -u)
    CUR_REGION=""
  fi

  local total_vms total_errs total_metrics regions_json per_region
  total_vms="$(jq -s 'unique_by(.id) | length' "$RAW_DIR/instances.jsonl" 2>/dev/null || echo 0)"
  total_metrics="$(wc -l < "$RAW_DIR/metrics.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
  total_errs="$(wc -l < "$RAW_DIR/errors.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
  regions_json="$(printf '%s\n' "${TARGET_REGIONS[@]}" | jq -R . | jq -s -c . 2>/dev/null || echo '[]')"
  per_region="$(jq -s -c 'unique_by(.id) | group_by(._oci_region // "default") | map({key: (.[0]._oci_region // "default"), value: length}) | from_entries' "$RAW_DIR/instances.jsonl" 2>/dev/null || echo '{}')"

  jq -n \
    --arg generated_at "$(ts_now)" \
    --arg collect_type "$COLLECT_TYPE" \
    --arg root_compartment "$COMP_ID" \
    --arg region "${FALLBACK_REGION}" \
    --argjson regions "$regions_json" \
    --argjson instances_by_region "$per_region" \
    --arg start_time "$start_time" \
    --arg end_time "$end_time" \
    --arg resolution "$RESOLUTION" \
    --argjson work_items "$total_items" \
    --argjson compartments_with_vms "$comps_with_vms" \
    --argjson instances_collected "$total_vms" \
    --argjson metric_datapoints "$total_metrics" \
    --argjson errors_recorded "$total_errs" \
    '{
      schema_version: "1.2",
      generated_at: $generated_at,
      collect_type: $collect_type,
      root_compartment: $root_compartment,
      default_region: $region,
      regions: $regions,
      window: {start_time: $start_time, end_time: $end_time, resolution: $resolution},
      counts: {
        region_compartment_items: $work_items,
        compartments_with_vms: $compartments_with_vms,
        instances_collected: $instances_collected,
        instances_by_region: $instances_by_region,
        metric_datapoints: $metric_datapoints,
        errors_recorded: $errors_recorded
      }
    }' > "$RAW_DIR/manifest.json"

  log_info "Milestone 1 ($COLLECT_TYPE) complete: $total_vms instance(s) across ${#TARGET_REGIONS[@]} region(s) $per_region, $total_metrics metric datapoint(s) saved in '$RAW_DIR' (isolated CLI errors/timeouts: $total_errs)."
  if [[ "$total_vms" -eq 0 ]]; then
    log_warn "0 instances found in region(s): ${TARGET_REGIONS[*]:-default}. Run './oci_to_mc.sh regions' to list subscribed regions and instance counts, then pass '--regions <r1,r2>'."
  fi
}

build_anon_map() {
  local map_entries="$TMP_WORK/anon_entries.jsonl"
  : > "$map_entries"
  if [[ "$ANONYMIZE" -eq 0 ]]; then
    printf '{}\n' > "$TMP_WORK/anon_map.json"
    return 0
  fi

  local tok h b1 b2 b3 masked
  while IFS= read -r tok; do
    [[ -n "$tok" ]] || continue
    local kind="${tok%%|*}"
    local raw="${tok#*|}"
    [[ -n "$raw" ]] || continue
    h="$(printf '%s:%s' "$ANON_SALT" "$raw" | sha256sum | awk '{print $1}')"
    case "$kind" in
      id)   masked="vm-${h:0:16}" ;;
      name) masked="host-${h:0:10}" ;;
      disk) masked="disk-${h:0:10}" ;;
      mac)  masked="02:${h:0:2}:${h:2:2}:${h:4:2}:${h:6:2}:${h:8:2}" ;;
      priv)
        b1=$(( (16#${h:0:2} % 250) + 1 ))
        b2=$(( (16#${h:2:2} % 250) + 1 ))
        b3=$(( (16#${h:4:2} % 250) + 1 ))
        masked="10.${b1}.${b2}.${b3}"
        ;;
      pub)
        b1=$(( (16#${h:0:2} % 250) + 1 ))
        masked="198.51.100.${b1}"
        ;;
      tag)  masked="redacted-${h:0:8}" ;;
    esac
    jq -cn --arg k "${kind}|${raw}" --arg v "$masked" '{key:$k, value:$v}' >> "$map_entries"
  done < <(
    {
      jq -r '["id|" + (.id // ""), "name|" + (.["display-name"] // "")] | .[]' "$RAW_DIR/instances.jsonl"
      jq -r '["mac|" + (.["mac-address"] // ""), "priv|" + (.["private-ip"] // ""), "pub|" + (.["public-ip"] // "")] | .[]' "$RAW_DIR/vnics.jsonl"
      jq -r '"disk|" + (.["display-name"] // .id // "")' "$RAW_DIR/volumes.jsonl" "$RAW_DIR/boot_volumes.jsonl"
      jq -r '((.["freeform-tags"] // {}) | to_entries[] | "tag|" + (.value | tostring)), ((.["defined-tags"] // {}) | to_entries[] | (.value // {}) | to_entries[] | "tag|" + (.value | tostring))' "$RAW_DIR/instances.jsonl"
    } | sort -u
  )

  jq -s 'from_entries' "$map_entries" > "$TMP_WORK/anon_map.json"
}

split_csv_if_needed() {
  local csv_file="$1" max_b="$2"
  [[ -f "$csv_file" ]] || return 0
  local fsize
  fsize="$(wc -c < "$csv_file" | tr -d ' ')"
  if [[ "$fsize" -le "$max_b" ]]; then
    return 0
  fi

  local header base dir count
  header="$(head -n 1 "$csv_file")"
  dir="$(dirname "$csv_file")"
  base="$(basename "$csv_file" .csv)"

  count="$(
    tail -n +2 "$csv_file" | awk -v hdr="$header" -v max_b="$max_b" -v pfx="${dir}/${base}_part" '
      BEGIN { part = 0; cur = max_b + 1; rows = 0 }
      {
        rlen = length($0) + 1
        if (cur + rlen > max_b && rows > 0) {
          close(fn)
          part++
          cur = max_b + 1
        }
        if (cur > max_b) {
          fn = sprintf("%s%03d.csv", pfx, part)
          print hdr > fn
          cur = length(hdr) + 1
          rows = 0
        }
        print $0 > fn
        cur += rlen
        rows++
      }
      END {
        if (fn != "") close(fn)
        print (rows > 0 ? part + 1 : 0)
      }
    '
  )"
  rm -f "$csv_file"
  log_info "Auto-split '$(basename "$csv_file")' ($fsize bytes > $max_b limit) into $count row-safe batch file(s) (${base}_part*.csv)."
}

validate_exported_csvs() {
  local max_b="$1"
  local expected_vm="MachineId,MachineName,PrimaryIPAddress(optional),PrimaryMACAddress(optional),PublicIPAddress(optional),IpAddressListSemiColonDelimited(optional),TotalDiskAllocatedGiB,TotalDiskUsedGiB,MachineTypeLabel(optional),AllocatedProcessorCoreCount,MemoryGiB,HostingLocation(optional),OsType(optional),OsPublisher(optional),OsName,OsVersion(optional),MachineStatus(optional),ProvisioningState(optional),CreateDate(optional),IsPhysical"
  local expected_disk="MachineId,DiskLabel,SizeInGib,UsedInGib,StorageTypeLabel"
  local expected_perf="MachineId,TimeStamp,CpuUtilizationPercentage,MemoryUtilizationPercentage(optional),AvailableMemoryBytes,DiskReadOperationsPerSec,DiskWriteOperationsPerSec,NetworkBytesPerSecSent,NetworkBytesPerSecReceived"
  local expected_tag="MachineId,Key,Value"

  local spec prefix expected f actual fsize
  for spec in \
    "vmInfo|$expected_vm" \
    "diskInfo|$expected_disk" \
    "perfInfo|$expected_perf" \
    "tagInfo|$expected_tag"; do
    prefix="${spec%%|*}"
    expected="${spec#*|}"
    local matched=0
    for f in "$OUT_DIR/${prefix}.csv" "$OUT_DIR/${prefix}_part"*.csv; do
      [[ -f "$f" ]] || continue
      matched=1
      actual="$(head -n 1 "$f")"
      [[ "$actual" == "$expected" ]] || die "Pre-flight CSV header mismatch in $f: got '$actual'"
      fsize="$(wc -c < "$f" | tr -d ' ')"
      [[ "$fsize" -le "$max_b" ]] || die "File $f ($fsize bytes) exceeds max upload threshold ($max_b bytes)."
    done
    [[ "$matched" -eq 1 ]] || die "Expected output CSV for '$prefix' was not generated in $OUT_DIR."
  done

  local vm_ids="$TMP_WORK/valid_vm_ids.txt"
  awk -F',' 'NR > 1 { gsub(/^"|"$/, "", $1); print $1 }' "$OUT_DIR"/vmInfo*.csv | sort -u > "$vm_ids"
  local vm_count
  vm_count="$(wc -l < "$vm_ids" | tr -d ' ')"
  [[ "$vm_count" -le 100000 ]] || die "Asset count ($vm_count) exceeds Migration Center 100,000 assets per project limit."

  local sub orphan
  for sub in diskInfo perfInfo tagInfo; do
    orphan="$(
      awk -F',' 'FNR > 1 { id = $1; gsub(/^"|"$/, "", id); print id }' "$OUT_DIR"/${sub}*.csv \
        | sort -u | comm -23 - "$vm_ids" | head -n 1 || true
    )"
    [[ -z "$orphan" ]] || die "Referential integrity error: MachineId '$orphan' in ${sub} is missing from vmInfo."
  done

  local bad_pct
  bad_pct="$(
    awk -F',' '
      FNR > 1 {
        for (i = 3; i <= 4; i++) {
          v = $i; gsub(/^"|"$/, "", v)
          if (v != "" && (v + 0 < 0 || v + 0 > 100)) { print FILENAME ":" FNR ":" v; exit }
        }
      }
    ' "$OUT_DIR"/perfInfo*.csv
  )"
  [[ -z "$bad_pct" ]] || die "Percentage out of [0..100] bounds in perfInfo ($bad_pct)."
}

export_mc() {
  [[ -d "$RAW_DIR" ]] || die "Snapshot directory '$RAW_DIR' does not exist. Run './oci_to_mc.sh collect' first."
  for stream in instances vnic_attachments vnics volume_attachments volumes boot_volume_attachments boot_volumes images metrics; do
    [[ -f "$RAW_DIR/${stream}.jsonl" ]] || : > "$RAW_DIR/${stream}.jsonl"
  done

  mkdir -p "$OUT_DIR"
  rm -f "$OUT_DIR"/vmInfo*.csv "$OUT_DIR"/diskInfo*.csv "$OUT_DIR"/perfInfo*.csv "$OUT_DIR"/tagInfo*.csv

  local default_loc="$REGION"
  if [[ -z "$default_loc" && -f "$RAW_DIR/manifest.json" ]]; then
    default_loc="$(jq -r '.default_region // ""' "$RAW_DIR/manifest.json")"
  fi

  log_info "Milestone 2 (export): Building offline bundle from '$RAW_DIR'..."
  build_anon_map

  jq -s '{
    instances: (.[0] | unique_by(.id)),
    vnic_att:  (.[1] | map(select(.["lifecycle-state"] == "ATTACHED" or .["lifecycle-state"] == null)) | unique_by(.id)),
    vnics:     (.[2] | unique_by(.id)),
    vol_att:   (.[3] | map(select(.["lifecycle-state"] == "ATTACHED" or .["lifecycle-state"] == null)) | unique_by(.id)),
    vols:      (.[4] | unique_by(.id)),
    bvol_att:  (.[5] | map(select(.["lifecycle-state"] == "ATTACHED" or .["lifecycle-state"] == null)) | unique_by(.id)),
    bvols:     (.[6] | unique_by(.id)),
    images:    (.[7] | unique_by(.id)),
    metrics:   (.[8] | unique_by([.metric_key, .resource_id, .timestamp])),
    anon:      (.[9][0])
  }' \
    <(jq -s '.' "$RAW_DIR/instances.jsonl") \
    <(jq -s '.' "$RAW_DIR/vnic_attachments.jsonl") \
    <(jq -s '.' "$RAW_DIR/vnics.jsonl") \
    <(jq -s '.' "$RAW_DIR/volume_attachments.jsonl") \
    <(jq -s '.' "$RAW_DIR/volumes.jsonl") \
    <(jq -s '.' "$RAW_DIR/boot_volume_attachments.jsonl") \
    <(jq -s '.' "$RAW_DIR/boot_volumes.jsonl") \
    <(jq -s '.' "$RAW_DIR/images.jsonl") \
    <(jq -s '.' "$RAW_DIR/metrics.jsonl") \
    <(jq -s '.' "$TMP_WORK/anon_map.json") \
    > "$TMP_WORK/bundle.json"

  cat <<'JQ_EOF' > "$TMP_WORK/mc_export.jq"
def norm_ts:
  if . == null or . == "" then ""
  else
    tostring
    | sub("\\.[0-9]+"; "")
    | sub("T"; " ")
    | if test("Z$") then sub("Z$"; "+00:00")
      elif test("[+-][0-9]{2}:[0-9]{2}$") then .
      else . + "+00:00"
      end
  end;

def mask($anon; $do_anon; $kind):
  if . == null or . == "" then ""
  elif $do_anon == 1 then ($anon[$kind + "|" + tostring] // tostring)
  elif $kind == "id" then (tostring | gsub("[^a-zA-Z0-9_-]"; "_"))
  else tostring
  end;

def mc_power_state:
  if . == null or . == "" then null
  else
    (tostring | ascii_upcase) as $s |
    if ($s == "RUNNING" or $s == "MOVING" or $s == "RESETTING" or $s == "CREATING_IMAGE") then "running"
    elif $s == "STOPPED" then "stopped"
    elif $s == "STOPPING" then "suspending"
    elif ($s == "PROVISIONING" or $s == "STARTING") then "pending"
    else null
    end
  end;

def mask_opt($anon; $do_anon; $kind):
  if . == null or . == "" then null
  elif $do_anon == 1 then ($anon[$kind + "|" + tostring] // tostring)
  else tostring
  end;

def region_full:
  if . == null or . == "" then ""
  elif . == "iad" then "us-ashburn-1"
  elif . == "phx" then "us-phoenix-1"
  else tostring
  end;

def inst_region($loc):
  if (._oci_region // "") != "" then ._oci_region
  elif (.region // "") != "" then (.region | region_full)
  else $loc
  end;

def opt_str:
  if . == null or . == "" then null else tostring end;

def storage_tier:
  ((.["vpus-per-gb"] // 10) | tonumber) as $vpu |
  if $vpu <= 0 then "LowerCost"
  elif $vpu < 20 then "Balanced"
  elif $vpu < 30 then "HigherPerformance"
  else "UltraHighPerformance"
  end;

def resolve_ocpus($shape; $sc):
  (($sc // {})["ocpus"] // null) as $cfg_o |
  if $cfg_o != null then ($cfg_o | tonumber)
  elif (($shape | tostring) | test("^(VM|BM)\\..*\\.[0-9]+$")) then
    (($shape | tostring | sub("^.*\\."; "")) | tonumber)
  else 1
  end;

def ocpu_to_vcpu($shape; $ocpus):
  (($ocpus // 1) | tonumber) as $o |
  (if (($shape | tostring) | test("\\.A[1-9]\\.|Ampere"; "i")) then ($o | ceil) else (($o * 2) | ceil) end) |
  if . < 1 then 1 else . end;

def clamp_pct:
  if . == null then null
  else tonumber | (if . < 0 then 0 elif . > 100 then 100 else . end) | ((((. * 100) + 0.5) | floor) / 100)
  end;

def clamp_nonneg:
  if . == null then null
  else tonumber | (if . < 0 then 0 else . end) | ((((. * 100) + 0.5) | floor) / 100)
  end;

def idx_by_id:
  reduce .[] as $x ({}; if ($x.id // "") != "" then .[($x.id | tostring)] = $x else . end);

def build_context($default_loc; $do_anon):
  . as $b |
  ($b.vnics  | idx_by_id) as $vnic_by_id |
  ($b.vols   | idx_by_id) as $vol_by_id  |
  ($b.bvols  | idx_by_id) as $bvol_by_id |
  ($b.images | idx_by_id) as $img_by_id  |
  (reduce $b.vnic_att[] as $va ({};
    ($vnic_by_id[($va["vnic-id"] // "")] // null) as $v |
    if ($v != null and ($va["instance-id"] // "") != "") then
      .[($va["instance-id"])] += [$v]
    else . end
  )) as $vnics_by_inst |
  (reduce $b.bvol_att[] as $ba ({};
    ($bvol_by_id[($ba["boot-volume-id"] // "")] // null) as $bv |
    if ($bv != null and ($ba["instance-id"] // "") != "") then
      .[($ba["instance-id"])] += [{
        vol_id: ($bv.id),
        label: ($bv["display-name"] // $bv.id),
        size_gib: (($bv["size-in-gbs"] // 50) | tonumber),
        tier: ("Boot-" + ($bv | storage_tier))
      }]
    else . end
  )) as $bvols_by_inst |
  (reduce $b.vol_att[] as $va ({};
    ($vol_by_id[($va["volume-id"] // "")] // null) as $vol |
    if ($vol != null and ($va["instance-id"] // "") != "") then
      .[($va["instance-id"])] += [{
        vol_id: ($vol.id),
        label: ($vol["display-name"] // $vol.id),
        size_gib: (($vol["size-in-gbs"] // 50) | tonumber),
        tier: ($vol | storage_tier)
      }]
    else . end
  )) as $vols_by_inst |
  {
    bundle: $b,
    anon: $b.anon,
    do_anon: $do_anon,
    default_loc: $default_loc,
    img_by_id: $img_by_id,
    vnics_by_inst: $vnics_by_inst,
    disks_by_inst: (
      reduce $b.instances[] as $inst ({};
        if ($inst.id // "") != "" then
          .[$inst.id] = (($bvols_by_inst[$inst.id] // []) + ($vols_by_inst[$inst.id] // []))
        else . end
      )
    )
  };
JQ_EOF

  # 1. vmInfo.csv
  log_verb "Generating $OUT_DIR/vmInfo.csv..."
  {
    printf 'MachineId,MachineName,PrimaryIPAddress(optional),PrimaryMACAddress(optional),PublicIPAddress(optional),IpAddressListSemiColonDelimited(optional),TotalDiskAllocatedGiB,TotalDiskUsedGiB,MachineTypeLabel(optional),AllocatedProcessorCoreCount,MemoryGiB,HostingLocation(optional),OsType(optional),OsPublisher(optional),OsName,OsVersion(optional),MachineStatus(optional),ProvisioningState(optional),CreateDate(optional),IsPhysical\n'
    jq -r --arg loc "$default_loc" --argjson anon "$ANONYMIZE" '
      include "mc_export";
      build_context($loc; $anon) as $ctx |
      $ctx.bundle.instances[] |
      select((.id // "") != "") |
      . as $inst |
      ($inst.shape // "VM.Standard") as $shape |
      resolve_ocpus($shape; $inst["shape-config"]) as $ocpus |
      ((($inst["shape-config"] // {})["memory-in-gbs"] // ($ocpus * 8)) | tonumber) as $mem_gib |
      ($ctx.vnics_by_inst[$inst.id] // []) as $vnics |
      (($vnics | map(select(.["is-primary"] == true))[0]) // ($vnics[0] // {})) as $pv |
      ([ $vnics[] | ((.["private-ip"] | mask($ctx.anon; $anon; "priv")), (.["public-ip"] | mask($ctx.anon; $anon; "pub"))) | select(. != "") ] | unique | join(";")) as $ip_list |
      ($ctx.disks_by_inst[$inst.id] // []) as $disks |
      (if ($disks | length) > 0 then ($disks | map(.size_gib) | add) else 50 end) as $total_disk |
      ($ctx.img_by_id[($inst["image-id"] // "")] // {}) as $img |
      ($img["operating-system"] // "Linux") as $os_name |
      ($img["operating-system-version"] // "") as $os_ver |
      (if ($os_name | test("Windows"; "i")) then "Windows" else "Linux" end) as $os_type |
      (($inst | inst_region($loc)) as $ir | if $ir != "" then $ir else ($inst["availability-domain"] // "") end) as $hloc |
      [
        ($inst.id | mask($ctx.anon; $anon; "id")),
        (($inst["display-name"] // $inst.id) | mask($ctx.anon; $anon; "name")),
        (($pv["private-ip"] // "") | mask_opt($ctx.anon; $anon; "priv")),
        (($pv["mac-address"] // "") | mask_opt($ctx.anon; $anon; "mac")),
        (($pv["public-ip"] // "") | mask_opt($ctx.anon; $anon; "pub")),
        ($ip_list | opt_str),
        $total_disk,
        null,
        ($shape | opt_str),
        ocpu_to_vcpu($shape; $ocpus),
        $mem_gib,
        ($hloc | opt_str),
        $os_type,
        $os_name,
        (if $os_ver != "" then ($os_name + " " + $os_ver) else $os_name end),
        ($os_ver | opt_str),
        (($inst["lifecycle-state"] // "RUNNING") | mc_power_state),
        null,
        ((($inst["time-created"] // "") | norm_ts) | opt_str),
        (if ($shape | startswith("BM.")) then 1 else 0 end)
      ] | @csv
    ' -L "$TMP_WORK" "$TMP_WORK/bundle.json"
  } > "$OUT_DIR/vmInfo.csv"

  # 2. diskInfo.csv
  log_verb "Generating $OUT_DIR/diskInfo.csv..."
  {
    printf 'MachineId,DiskLabel,SizeInGib,UsedInGib,StorageTypeLabel\n'
    jq -r --arg loc "$default_loc" --argjson anon "$ANONYMIZE" '
      include "mc_export";
      build_context($loc; $anon) as $ctx |
      $ctx.bundle.instances[] |
      select((.id // "") != "") |
      . as $inst |
      ($ctx.disks_by_inst[$inst.id] // [])[] |
      [
        ($inst.id | mask($ctx.anon; $anon; "id")),
        (.label | mask($ctx.anon; $anon; "disk")),
        .size_gib,
        null,
        .tier
      ] | @csv
    ' -L "$TMP_WORK" "$TMP_WORK/bundle.json"
  } > "$OUT_DIR/diskInfo.csv"

  # 3. perfInfo.csv (empirical MQL series + attached blockstore IOPS fallback; empty cell for missing metrics)
  log_verb "Generating $OUT_DIR/perfInfo.csv..."
  {
    printf 'MachineId,TimeStamp,CpuUtilizationPercentage,MemoryUtilizationPercentage(optional),AvailableMemoryBytes,DiskReadOperationsPerSec,DiskWriteOperationsPerSec,NetworkBytesPerSecSent,NetworkBytesPerSecReceived\n'
    jq -r --arg loc "$default_loc" --argjson anon "$ANONYMIZE" '
      include "mc_export";
      build_context($loc; $anon) as $ctx |
      ($ctx.bundle.instances | map(select((.id // "") != "") | {key: .id, value: true}) | from_entries) as $valid_inst |
      (reduce ($ctx.bundle.instances[]) as $inst ({};
        if ($inst.id // "") != "" then
          reduce ($ctx.disks_by_inst[$inst.id] // [])[] as $d (.; .[$d.vol_id] = $inst.id)
        else . end
      )) as $vol_to_inst |
      (reduce $ctx.bundle.metrics[] as $m ({};
        ($m.timestamp | norm_ts) as $ts |
        if ($m.metric_key == "vol_r" or $m.metric_key == "vol_w") then
          ($vol_to_inst[($m.resource_id // "")] // "") as $iid |
          if ($iid != "" and ($valid_inst[$iid] // false)) then
            ($iid + "|" + $ts) as $pk |
            .[$pk] = ((.[$pk] // {iid: $iid, ts: $ts}) + {($m.metric_key): (((.[$pk] // {})[$m.metric_key] // 0) + ($m.value | tonumber))})
          else . end
        elif (($m.resource_id // "") != "" and ($valid_inst[($m.resource_id // "")] // false)) then
          (($m.resource_id // "") + "|" + $ts) as $pk |
          .[$pk] = ((.[$pk] // {iid: $m.resource_id, ts: $ts}) + {($m.metric_key): ($m.value | tonumber)})
        else . end
      )) |
      to_entries | sort_by(.key)[] | .value as $p |
      (($p.disk_r // $p.vol_r // null) | clamp_nonneg) as $dr |
      (($p.disk_w // $p.vol_w // null) | clamp_nonneg) as $dw |
      [
        ($p.iid | mask($ctx.anon; $anon; "id")),
        $p.ts,
        (($p.cpu // null) | clamp_pct),
        (($p.mem // null) | clamp_pct),
        null,
        $dr,
        $dw,
        (($p.net_out // null) | clamp_nonneg),
        (($p.net_in // null) | clamp_nonneg)
      ] | @csv
    ' -L "$TMP_WORK" "$TMP_WORK/bundle.json"
  } > "$OUT_DIR/perfInfo.csv"

  # 4. tagInfo.csv
  log_verb "Generating $OUT_DIR/tagInfo.csv..."
  {
    printf 'MachineId,Key,Value\n'
    jq -r --arg loc "$default_loc" --argjson anon "$ANONYMIZE" '
      include "mc_export";
      build_context($loc; $anon) as $ctx |
      $ctx.bundle.instances[] |
      select((.id // "") != "") |
      . as $inst |
      ($inst.id | mask($ctx.anon; $anon; "id")) as $mid |
      resolve_ocpus(($inst.shape // "VM.Standard"); $inst["shape-config"]) as $ocpus |
      (
        (if $anon == 0 then [{k: "oci:ocid", v: ($inst.id | tostring)}] else [] end) +
        [
          {k: "oci:region", v: ($inst | inst_region($loc))},
          {k: "oci:shape", v: ($inst.shape // "VM.Standard")},
          {k: "oci:ocpus", v: ($ocpus | tostring)}
        ] +
        [
          ($inst["freeform-tags"] // {}) | to_entries[] |
          {k: (.key | tostring), v: ((.value | tostring) | mask($ctx.anon; $anon; "tag"))}
        ] +
        [
          ($inst["defined-tags"] // {}) | to_entries[] | .key as $ns |
          (.value // {}) | to_entries[] |
          {k: ($ns + "." + (.key | tostring)), v: ((.value | tostring) | mask($ctx.anon; $anon; "tag"))}
        ]
      )[] |
      select(.k != "" and .v != "") |
      [$mid, .k, .v] | @csv
    ' -L "$TMP_WORK" "$TMP_WORK/bundle.json"
  } > "$OUT_DIR/tagInfo.csv"

  local max_b
  if [[ -n "$MAX_BYTES" ]]; then
    max_b="$MAX_BYTES"
  else
    max_b=$(( MAX_MB * 1024 * 1024 ))
  fi

  for csv_f in "$OUT_DIR/vmInfo.csv" "$OUT_DIR/diskInfo.csv" "$OUT_DIR/perfInfo.csv" "$OUT_DIR/tagInfo.csv"; do
    split_csv_if_needed "$csv_f" "$max_b"
  done

  validate_exported_csvs "$max_b"
  log_info "Milestone 2 (export) & Pre-Flight CSV Validation PASSED -> $OUT_DIR"
}

check_local_deps
case "$MODE" in
  preflight) preflight_oci ;;
  regions)   report_regions ;;
  collect)   collect_oci ;;
  export)    export_mc ;;
  run)       collect_oci; export_mc ;;
esac
