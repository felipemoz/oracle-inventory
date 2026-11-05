# oracle-inventory — OCI CLI to Google Cloud Migration Center Exporter (`oci_to_mc.sh`)

A resilient, standalone Bash utility for extracting compute instance inventory, block storage topology, and empirical Monitoring Query Language (MQL) performance metrics from **Oracle Cloud Infrastructure (OCI)** and converting them into Google Cloud **Migration Center Manual Import CSVs** (`vmInfo.csv`, `diskInfo.csv`, `perfInfo.csv`, and `tagInfo.csv`).

---

## Key Capabilities

- **Zero Heavy Dependencies**: Runs directly inside **OCI Cloud Shell** or any Linux workstation using native `oci` CLI, `jq` (`>= 1.5`), `timeout`, and `awk`. No Python virtual environments or external packages required.
- **Selectable Collection Scope (`-t / --collect-type` + Interactive Menu)**:
  - `full` (`1`, default): Complete extraction — VMs, OS images, VNICs, Boot/Block Volumes, Tags, and 8 MQL performance metric series.
  - `inventory` (`2`, fast / no-metrics): Extracts VMs, OS images, VNICs, Boot/Block Volumes, and Tags while skipping slow 30-day OCI Monitoring MQL queries.
  - `compute-only` (`3`, ultra-fast): Extracts only VMs (`compute instance list`) and OS images (`compute image get`).
  - `metrics-only` (`4`, complementary): Queries MQL metrics **only** on compartments that already contain active VMs in `--raw-dir/instances.jsonl`.
- **Multi-Region by Default**: Automatically discovers every subscribed OCI region (`iam region-subscription list`) — not only the home region where the tenancy was created — and uses regional **OCI Resource Search** to scan only the compartments that actually contain instances in each region (with a safe full-scan fallback). Restrict with `--regions sa-saopaulo-1,sa-vinhedo-1`.
- **Parallel, Low-Call-Count Collection**:
  - Bounded parallel engine (`-P / --parallel`, default `8`) runs independent OCI CLI calls concurrently: regional searches, per-compartment instance lists, VNIC/volume/boot-volume lists, OS image lookups and metric queries.
  - Tenancy-wide metrics (`--metrics-scope auto`, default when scanning from the tenancy root): **one** MQL query per metric per region (`compartmentIdInSubtree=true`) instead of one per compartment, with automatic per-compartment fallback if OCI rejects the query (e.g. too many data points).
  - Milestone 2 generates the four CSVs concurrently.
- **Two Decoupled Milestones**:
  - **Milestone 1 (`collect`)**: Discovers compartments, queries compute instances, attached boot/block volumes, VNICs, and extracts historical performance metrics into a local JSONL snapshot (`./oci_raw_snapshot/`).
  - **Milestone 2 (`export`)**: Processes the snapshot **100% offline** (zero OCI or GCP network calls) and outputs validated Migration Center CSVs (`./mc_export_csv/`).
- **Resilient 4-Layer Fault Handling & Timeout Circuit Breaker**:
  - Operating-system process watchdog (`timeout --kill-after=10s`) catching hung sockets or stalled pagination.
  - Automatic exponential backoff retries for transient errors (`ReadTimeout`, HTTP `429`, `503`).
  - Per-compartment MQL circuit breaker (`--max-metric-timeouts 2`) that skips remaining MQL queries in a compartment after consecutive timeouts instead of stalling.
  - Compartment-level isolation logging failures to `errors.jsonl` without aborting remaining inventory, plus `--resume` checkpointing.
- **Migration Center Specification Compliance**:
  - Sanitizes OCI OCID identifiers to meet Migration Center's `^[a-zA-Z0-9-_]*$` regex validator.
  - Maps OCI lifecycle states to valid Migration Center power states (`running`, `stopped`, `pending`, `suspending`).
  - Converts OCI OCPUs to vCPUs for both x86 (`1 OCPU = 2 vCPUs`) and Ampere ARM (`1 OCPU = 1 vCPU`), including legacy fixed shapes (`VM.Standard2.*`).
  - Automatically splits CSV files larger than **95 MiB** while preserving headers to stay under the 100 MB Migration Center upload threshold.
- **Privacy & Anonymization Mode (`--anonymize`)**:
  - Replaces machine names, private/public IPs, MAC addresses, volume labels, and tag values with deterministic SHA-256 hashes (`vm-xxxxxxxx`, `host-xxxxxxxx`, `10.x.x.x`).

---

## Architecture Overview

```
       +-------------------------------------------------------------+
       |                  ORACLE CLOUD INFRASTRUCTURE                |
       +-------------------------------------------------------------+
              |                                        |
              | (compute / bv / iam)                   | (monitoring MQL)
              v                                        v
       +-------------------------------------------------------------+
       |                Milestone 1: collect_oci()                   |
       |  - Preflight validation (IAM, ~/.oci/config, profile)       |
       |  - Selectable --collect-type (full/inventory/compute/perf)  |
       |  - 4-layer watchdog, backoff retry & MQL circuit breaker    |
       +-------------------------------------------------------------+
                                      |
                                      v
       +-------------------------------------------------------------+
       |               Local Snapshot: ./oci_raw_snapshot/           |
       |  - instances.jsonl         - volumes.jsonl                  |
       |  - vnics.jsonl             - metrics.jsonl (MQL series)     |
       |  - manifest.json           - errors.jsonl                   |
       +-------------------------------------------------------------+
                                      |
                                      v (100% Offline via jq)
       +-------------------------------------------------------------+
       |                Milestone 2: export_mc()                     |
       |  - OCPU -> vCPU conversion (x86, ARM & Fixed Shapes)        |
       |  - Blockstore IOPS fallback (when agent is missing)         |
       |  - Row-safe CSV splitting (<95 MiB)                         |
       +-------------------------------------------------------------+
                                      |
                                      v
       +-------------------------------------------------------------+
       |             Google Cloud Migration Center CSVs              |
       |  - vmInfo.csv              - perfInfo.csv                   |
       |  - diskInfo.csv            - tagInfo.csv                    |
       +-------------------------------------------------------------+
```

---

## Prerequisites

1. **OCI Cloud Shell** (Recommended) or a Linux workstation with:
   - `oci` CLI (`>= 3.0.0`)
   - `jq` (`>= 1.5`)
   - Standard core utilities: `bash`, `awk`, `timeout`, `sha256sum`
2. **OCI Identity & Access (IAM) Read Permissions**:
   Administrators already have full read access. For least-privilege read access across the target tenancy:
   ```text
   allow group MigrationAdvisors to read all-resources in tenancy
   allow group MigrationAdvisors to read metrics in tenancy
   ```

---

## Quick Start

### 1. Clone or Download Single Script (OCI Cloud Shell or Workstation)

```bash
# Option A: Clone the repository
git clone https://github.com/felipemoz/oracle-inventory.git
cd oracle-inventory
chmod +x oci_to_mc.sh

# Option B: Direct single-file download via curl
curl -fsSL https://raw.githubusercontent.com/felipemoz/oracle-inventory/main/oci_to_mc.sh -o oci_to_mc.sh
chmod +x oci_to_mc.sh

# Run end-to-end (interactive menu in terminal, or pass -t)
./oci_to_mc.sh run
```

### 2. Validate Regions First (`regions` mode)

List every subscribed region with its instance and compartment counts before collecting:

```bash
./oci_to_mc.sh regions
#
# REGION                   INSTANCES    COMPARTMENTS
# ------------------------ ------------ --------------
# sa-saopaulo-1            42           7
# sa-vinhedo-1             11           3
# us-ashburn-1             0            0
```

By default `run` / `collect` cover **all** subscribed regions. To limit the scope:

```bash
./oci_to_mc.sh run --collect-type inventory --regions sa-saopaulo-1,sa-vinhedo-1 -v
```

Each VM is exported with `HostingLocation` set to the region it was collected from, plus an `oci:region` tag in `tagInfo.csv`.

### 3. Tuning Speed (`-P / --parallel`, `--metrics-scope`)

```bash
# Default: 8 concurrent OCI CLI calls + tenancy-wide metric queries
./oci_to_mc.sh run --collect-type full -v

# Large tenancy with headroom: raise concurrency (OCI throttling/HTTP 429 is retried automatically)
./oci_to_mc.sh run --collect-type full -P 16 -v

# Constrained shell or strict API limits: lower concurrency
./oci_to_mc.sh run --collect-type full -P 4 -v
```

Each OCI CLI call is a separate Python process, so very high `-P` values mostly add memory pressure and throttling rather than speed. The per-phase timings printed in the log (`Phase 1/4 ... Phase 4/4`) and `manifest.json` (`execution.elapsed_seconds`) help pick the right value.

### 4. Choosing the Collection Type (`--collect-type`)

You can select the extraction scope interactively when running in a terminal, or pass `-t / --collect-type` for `nohup` / background runs:

```bash
# [1] Full (Default): VMs + OS + VNICs + Boot/Block Volumes + 8 MQL performance metrics
nohup ./oci_to_mc.sh run --collect-type full -v > nohup_full.out 2>&1 &

# [2] Inventory Only (Fast — skips slow MQL monitoring queries that often time out):
nohup ./oci_to_mc.sh run --collect-type inventory -v > nohup_inventory.out 2>&1 &

# [3] Compute Only (Ultra-Fast: VMs + Shapes + Tags + OS images only):
nohup ./oci_to_mc.sh run --collect-type compute-only -v > nohup_compute.out 2>&1 &

# [4] Metrics Only (Complementary: queries MQL metrics ONLY on compartments with VMs in --raw-dir):
nohup ./oci_to_mc.sh collect --collect-type metrics-only -v > nohup_metrics.out 2>&1 &
./oci_to_mc.sh export
```

### 5. Standalone Workflow (Step-by-Step)

```bash
# Step 1: Validate configuration and IAM permissions
./oci_to_mc.sh preflight

# Step 2: Extract inventory and metrics (lookback 30 days, 1-hour interval)
./oci_to_mc.sh collect --collect-type full --days 30 --resolution 1h -v

# Step 3: Convert to Migration Center CSVs (completely offline)
./oci_to_mc.sh export --out-dir ./mc_export_csv
```

### 6. Anonymized Execution

To mask hostnames, IPs, MACs, and OCIDs via SHA-256 before sharing CSVs:

```bash
./oci_to_mc.sh run --anonymize --anonymize-salt "my-custom-audit-salt"
```

---

## Command-Line Options

| Option | Default | Description |
| :--- | :--- | :--- |
| `-c, --compartment-ocid <OCID>` | Tenancy root | Root compartment or tenancy OCID to scan |
| `-t, --collect-type <TYPE>` | `full` (or interactive) | `full` (`1`), `inventory` (`2`), `compute-only` (`3`), or `metrics-only` (`4`) |
| `-v, --verbose` | Enabled | Verbose progress + full OCI CLI command trace with elapsed timers |
| `-q, --quiet` | Disabled | Quiet mode (summary and errors only) |
| `--regions <all\|r1,r2>` | `all` subscribed | Regions to collect (e.g. `sa-saopaulo-1,sa-vinhedo-1`) |
| `--region <REGION>` | — | Single-region shortcut (same as `--regions <REGION>`) |
| `--auth <MODE>` | Auto-detected | `api_key`, `security_token`, `instance_obo_user` (Cloud Shell), or `instance_principal` |
| `--config-file <PATH>` | `~/.oci/config` | OCI CLI configuration file |
| `--profile <NAME>` | `DEFAULT` | OCI configuration profile |
| `--days <INT>` | `30` | Performance metric lookback window in days (up to 90 for `1h` resolution) |
| `--resolution <1m\|5m\|1h>` | `1h` | MQL interval (`1m` max 7d, `5m` max 30d, `1h` max 90d) |
| `--conn-timeout <SEC>` | `15` | OCI CLI network connection timeout |
| `--read-timeout <SEC>` | `90` | OCI CLI HTTP read timeout |
| `--cmd-timeout <SEC>` | `180` | OS watchdog timeout per command before SIGKILL |
| `--retries <INT>` | `3` | Max retry attempts for transient timeout/network failures |
| `-P, --parallel <N>` | `8` | Max concurrent OCI CLI calls (`1` = sequential, max `64`) |
| `--metrics-scope <MODE>` | `auto` | `auto`/`region` = one tenancy-wide MQL query per metric per region; `compartment` = one per compartment |
| `--max-metric-timeouts <INT>` | `2` | Circuit breaker: skip remaining MQL queries in a compartment after N consecutive timeouts |
| `--resume` | Disabled | Skip compartments completed successfully in a previous run |
| `--anonymize` | Disabled | Deterministically mask IDs, hostnames, IPs, and MACs via SHA-256 |
| `--max-mb <INT>` | `95` | Maximum CSV size in MiB before row-safe splitting (Migration Center limit is 100 MB) |
| `--raw-dir <DIR>` | `./oci_raw_snapshot` | Snapshot storage directory |
| `--out-dir <DIR>` | `./mc_export_csv` | Generated CSV output directory |

---

## Importing into Google Cloud Migration Center

1. Open the [Google Cloud Console](https://console.cloud.google.com/).
2. Navigate to **Migration Center** > **Asset inventory**.
3. Click **Import data** > **Upload files**.
4. Select **Manual import (CSV files)**.
5. Upload the generated files from `./mc_export_csv/`:
   - `vmInfo.csv` (or batch parts `vmInfo_part000.csv`, etc.)
   - `diskInfo.csv`
   - `perfInfo.csv`
   - `tagInfo.csv`
6. Click **Confirm import**. Migration Center parses the infrastructure details and generates machine-rightsizing recommendations and Google Cloud cost estimates.

---

## License

This software is released under the **Apache 2.0 License**. See [LICENSE](LICENSE) for details.
