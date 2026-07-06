#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "GitSizer Repository Readiness Check"
echo "=========================================="

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
THRESHOLD_BYTES="${GIT_SIZER_LARGE_FILE_THRESHOLD_BYTES:-419430400}" # 400 MB
THRESHOLD_MB=$((THRESHOLD_BYTES / 1024 / 1024))

INVENTORY_FILE="${INVENTORY_FILE:-gitlab-stats.csv}"
SOURCE_GL_SERVER_URL="${SOURCE_GL_SERVER_URL:-}"
GITLAB_USERNAME="${GITLAB_USERNAME:-}"
GITLAB_API_PRIVATE_TOKEN="${GITLAB_API_PRIVATE_TOKEN:-}"

OUT_DIR="output_files/git-sizer-readiness"
LOG_DIR="logs"
WORK_DIR=".gitsizer-work"
TOOLS_DIR=".tools"

SUMMARY_CSV="$OUT_DIR/repo-size-summary.csv"
REPO_METRICS_CSV="$OUT_DIR/repo-metrics.csv"
LARGE_FILES_CSV="$OUT_DIR/large-files-above-${THRESHOLD_MB}mb.csv"
REPO_LIST_TSV="$OUT_DIR/repositories.tsv"
FINAL_REPORT="$OUT_DIR/final-report.txt"

PER_REPO_CSV_DIR="$OUT_DIR/per-repo-csv"
PER_REPO_LARGE_FILES_DIR="$OUT_DIR/per-repo-large-files"

mkdir -p "$OUT_DIR/gitsizer-json" \
         "$OUT_DIR/gitsizer-text" \
         "$PER_REPO_CSV_DIR" \
         "$PER_REPO_LARGE_FILES_DIR" \
         "$LOG_DIR" \
         "$WORK_DIR" \
         "$TOOLS_DIR"

LOG_FILE="$LOG_DIR/git-sizer-readiness-check.log"

exec > >(tee -a "$LOG_FILE") 2>&1

ROOT_DIR="$(pwd)"

echo "[INFO] Inventory file       : $INVENTORY_FILE"
echo "[INFO] Output directory     : $OUT_DIR"
echo "[INFO] Log file             : $LOG_FILE"
echo "[INFO] Large file threshold : ${THRESHOLD_MB} MB"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------
if [[ ! -s "$INVENTORY_FILE" ]]; then
  echo "[ERROR] Inventory file missing or empty: $INVENTORY_FILE"
  exit 1
fi

if [[ -z "$SOURCE_GL_SERVER_URL" ]]; then
  echo "[ERROR] SOURCE_GL_SERVER_URL is required"
  exit 1
fi

if [[ -z "$GITLAB_USERNAME" ]]; then
  echo "[ERROR] GITLAB_USERNAME is required"
  exit 1
fi

if [[ -z "$GITLAB_API_PRIVATE_TOKEN" ]]; then
  echo "[ERROR] GITLAB_API_PRIVATE_TOKEN is required"
  exit 1
fi

# ------------------------------------------------------------
# CSV helpers
# ------------------------------------------------------------
csv_quote() {
  local value="${1:-}"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

csv_row() {
  local first="true"
  local value

  for value in "$@"; do
    if [[ "$first" == "true" ]]; then
      first="false"
    else
      printf ','
    fi

    csv_quote "$value"
  done

  printf '\n'
}

safe_name() {
  echo "$1" | sed 's#[^A-Za-z0-9._-]#_#g'
}

bytes_to_mb() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 }'
}

line_count() {
  local file="$1"

  if [[ -s "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    echo "0"
  fi
}

# ------------------------------------------------------------
# Install git-sizer if missing
# ------------------------------------------------------------
install_git_sizer() {
  if command -v git-sizer >/dev/null 2>&1; then
    echo "[INFO] git-sizer detected: $(git-sizer --version 2>/dev/null || true)"
    return
  fi

  echo "[INFO] git-sizer not found. Installing git-sizer locally..."

  if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required to install git-sizer"
    exit 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq is required to install git-sizer"
    exit 1
  fi

  if ! command -v unzip >/dev/null 2>&1; then
    echo "[WARN] unzip is not installed."

    if sudo -n true >/dev/null 2>&1; then
      echo "[INFO] Installing unzip..."
      sudo apt-get update -y
      sudo apt-get install -y unzip
    else
      echo "[ERROR] unzip is required to extract git-sizer."
      echo "[ACTION REQUIRED] Install unzip on the runner or install it in the environment preparation job."
      exit 1
    fi
  fi

  ASSET_URL="$(
    curl -fsSL "https://api.github.com/repos/github/git-sizer/releases/latest" |
      jq -r '.assets[]
        | select(.name | test("linux-amd64.*\\.zip$"))
        | .browser_download_url' |
      head -n1
  )"

  if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
    echo "[ERROR] Unable to find linux-amd64 git-sizer release asset"
    exit 1
  fi

  echo "[INFO] Downloading git-sizer from latest GitHub release..."

  curl -fsSL "$ASSET_URL" -o "$TOOLS_DIR/git-sizer.zip"

  rm -rf "$TOOLS_DIR/git-sizer-extract"
  mkdir -p "$TOOLS_DIR/git-sizer-extract"

  unzip -q "$TOOLS_DIR/git-sizer.zip" -d "$TOOLS_DIR/git-sizer-extract"

  GIT_SIZER_BIN="$(find "$TOOLS_DIR/git-sizer-extract" -type f -name git-sizer | head -n1)"

  if [[ -z "$GIT_SIZER_BIN" ]]; then
    echo "[ERROR] git-sizer binary not found after extraction"
    exit 1
  fi

  chmod +x "$GIT_SIZER_BIN"
  cp "$GIT_SIZER_BIN" "$TOOLS_DIR/git-sizer"
  chmod +x "$TOOLS_DIR/git-sizer"

  export PATH="$ROOT_DIR/$TOOLS_DIR:$PATH"

  git-sizer --version >/dev/null 2>&1 || {
    echo "[ERROR] git-sizer installation validation failed"
    exit 1
  }

  echo "[INFO] git-sizer installed locally: $ROOT_DIR/$TOOLS_DIR/git-sizer"
}

# ------------------------------------------------------------
# Create repository list from inventory
# Header-independent: Extract first http/https Git URL from each row
# ------------------------------------------------------------
create_repo_list() {
  echo "[INFO] Reading repositories from $INVENTORY_FILE"

  CLEAN_CSV="$OUT_DIR/gitlab-stats.cleaned.csv"
  sed '1s/^\xEF\xBB\xBF//' "$INVENTORY_FILE" | tr -d '\r' > "$CLEAN_CSV"

  echo
  echo "===== CSV HEADER (first line) ====="
  head -n 1 "$CLEAN_CSV"
  echo

  echo "===== CSV FIRST DATA ROW ====="
  sed -n '2p' "$CLEAN_CSV"
  echo

  awk -F',' '
  function trim(s) {
    gsub(/^[ \t\r\n"]+|[ \t\r\n"]+$/, "", s)
    return s
  }

  NR==1 { next }

  {
      repo_url = ""

      for (i = 1; i <= NF; i++) {
          v = trim($i)

          if (v ~ /^https?:\/\/[^ ,]+/) {
              repo_url = v
              break
          }
      }

      if (repo_url == "") {
          print "[WARN] Skipping row - no http(s) URL field found" > "/dev/stderr"
          next
      }

      path = repo_url
      sub(/^https?:\/\/[^\/]+\//, "", path)
      sub(/\.git$/, "", path)
      sub(/\/$/, "", path)

      n = split(path, parts, "/")

      if (n < 2) {
          print "[WARN] Skipping row - could not derive namespace/project from URL: " repo_url > "/dev/stderr"
          next
      }

      project = parts[n]
      namespace = parts[1]

      for (i = 2; i < n; i++) {
          namespace = namespace "/" parts[i]
      }

      print project "\t" repo_url "\t" namespace "/" project
      count++
  }

  END {
      if (count == 0) {
          print "[ERROR] No valid repositories found from inventory file" > "/dev/stderr"
          exit 3
      }
  }
  ' "$CLEAN_CSV" > "$REPO_LIST_TSV" || {
    echo "[ERROR] Failed to parse inventory file. See errors above."
    exit 1
  }

  echo "[INFO] Repository list generated: $REPO_LIST_TSV"
  echo "[INFO] Repository count: $(wc -l < "$REPO_LIST_TSV" | tr -d ' ')"

  echo
  echo "===== Repository List ====="
  cat "$REPO_LIST_TSV"
  echo
}

# ------------------------------------------------------------
# CSV headers
# ------------------------------------------------------------
write_headers() {
  csv_row \
    "repo_name" \
    "project_path" \
    "repo_url" \
    "mirror_repo_size_mb" \
    "largest_blob_mb" \
    "large_file_count" \
    "threshold_mb" \
    "migration_risk" \
    "migration_warning" \
    "status" \
    > "$SUMMARY_CSV"

  csv_row \
    "repo_name" \
    "project_path" \
    "repo_url" \
    "mirror_repo_size_mb" \
    "branch_count" \
    "tag_count" \
    "remote_ref_count" \
    "all_ref_count" \
    "commit_count" \
    "blob_count" \
    "tree_count" \
    "total_blob_size_mb" \
    "largest_blob_mb" \
    "total_tree_size_mb" \
    "largest_tree_mb" \
    "large_file_count" \
    "threshold_mb" \
    "migration_risk" \
    "migration_warning" \
    "gitsizer_json_report" \
    "gitsizer_text_report" \
    "per_repo_csv" \
    "per_repo_large_files_csv" \
    "status" \
    > "$REPO_METRICS_CSV"

  csv_row \
    "repo_name" \
    "project_path" \
    "repo_url" \
    "blob_sha" \
    "blob_size_mb" \
    "file_path" \
    "threshold_mb" \
    "migration_risk" \
    "migration_warning" \
    "status" \
    > "$LARGE_FILES_CSV"
}

append_summary() {
  local repo_name="$1"
  local project_path="$2"
  local repo_url="$3"
  local repo_size_mb="$4"
  local largest_blob_mb="$5"
  local large_file_count="$6"
  local migration_risk="$7"
  local migration_warning="$8"
  local status="$9"

  csv_row \
    "$repo_name" \
    "$project_path" \
    "$repo_url" \
    "$repo_size_mb" \
    "$largest_blob_mb" \
    "$large_file_count" \
    "$THRESHOLD_MB" \
    "$migration_risk" \
    "$migration_warning" \
    "$status" \
    >> "$SUMMARY_CSV"
}

append_repo_metrics() {
  csv_row "$@" >> "$REPO_METRICS_CSV"
}

write_empty_per_repo_large_files_csv() {
  local per_repo_large_files_csv="$1"

  csv_row \
    "repo_name" \
    "project_path" \
    "repo_url" \
    "blob_sha" \
    "blob_size_mb" \
    "file_path" \
    "threshold_mb" \
    "migration_risk" \
    "migration_warning" \
    "status" \
    > "$per_repo_large_files_csv"
}

write_per_repo_csv_header() {
  local per_repo_csv="$1"

  csv_row \
    "repo_name" \
    "project_path" \
    "repo_url" \
    "mirror_repo_size_mb" \
    "branch_count" \
    "tag_count" \
    "remote_ref_count" \
    "all_ref_count" \
    "commit_count" \
    "blob_count" \
    "tree_count" \
    "total_blob_size_mb" \
    "largest_blob_mb" \
    "total_tree_size_mb" \
    "largest_tree_mb" \
    "large_file_count" \
    "threshold_mb" \
    "migration_risk" \
    "migration_warning" \
    "gitsizer_json_report" \
    "gitsizer_text_report" \
    "per_repo_large_files_csv" \
    "status" \
    > "$per_repo_csv"
}

write_per_repo_csv_row() {
  local per_repo_csv="$1"
  shift

  csv_row "$@" >> "$per_repo_csv"
}

append_large_files() {
  local large_tsv="$1"
  local repo_name="$2"
  local project_path="$3"
  local repo_url="$4"
  local per_repo_large_files_csv="$5"
  local migration_risk="$6"
  local migration_warning="$7"
  local status="$8"

  write_empty_per_repo_large_files_csv "$per_repo_large_files_csv"

  while IFS=$'\t' read -r blob_sha blob_size_mb file_path; do
    [[ -z "${blob_sha:-}" ]] && continue

    csv_row \
      "$repo_name" \
      "$project_path" \
      "$repo_url" \
      "$blob_sha" \
      "$blob_size_mb" \
      "$file_path" \
      "$THRESHOLD_MB" \
      "$migration_risk" \
      "$migration_warning" \
      "$status" \
      >> "$LARGE_FILES_CSV"

    csv_row \
      "$repo_name" \
      "$project_path" \
      "$repo_url" \
      "$blob_sha" \
      "$blob_size_mb" \
      "$file_path" \
      "$THRESHOLD_MB" \
      "$migration_risk" \
      "$migration_warning" \
      "$status" \
      >> "$per_repo_large_files_csv"
  done < "$large_tsv"
}

# ------------------------------------------------------------
# Git authentication for GitLab clone
# ------------------------------------------------------------
create_askpass() {
  ASKPASS_SCRIPT="$WORK_DIR/git-askpass.sh"

  cat > "$ASKPASS_SCRIPT" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *Username*) echo "$GITLAB_USERNAME" ;;
  *Password*) echo "$GITLAB_API_PRIVATE_TOKEN" ;;
  *) echo "$GITLAB_API_PRIVATE_TOKEN" ;;
esac
EOF

  chmod +x "$ASKPASS_SCRIPT"

  export GIT_ASKPASS="$ROOT_DIR/$ASKPASS_SCRIPT"
  export GIT_TERMINAL_PROMPT=0
}

# ------------------------------------------------------------
# Run GitSizer discovery
# ------------------------------------------------------------
run_checks() {
  local total_repos=0
  local failed_clone_repos=0
  local passed_repos=0
  local warning_repos=0
  local high_risk_repos=0

  local warning_summary_file="$OUT_DIR/warning-summary.txt"
  local clone_failures_file="$OUT_DIR/clone-failures.txt"
  local high_risk_repos_file="$OUT_DIR/high-risk-migration-repos.txt"

  : > "$warning_summary_file"
  : > "$clone_failures_file"
  : > "$high_risk_repos_file"

  create_askpass

  while IFS=$'\t' read -r repo_name repo_url project_path; do
    total_repos=$((total_repos + 1))

    safe_repo_name="$(safe_name "$project_path")"
    repo_dir="$WORK_DIR/${safe_repo_name}.git"

    gitsizer_json_report="$OUT_DIR/gitsizer-json/${safe_repo_name}.json"
    gitsizer_text_report="$OUT_DIR/gitsizer-text/${safe_repo_name}.txt"
    per_repo_csv="$PER_REPO_CSV_DIR/${safe_repo_name}.csv"
    per_repo_large_files_csv="$PER_REPO_LARGE_FILES_DIR/${safe_repo_name}-large-files.csv"

    echo
    echo "--------------------------------------------------"
    echo "[INFO] Checking repo : $repo_name"
    echo "[INFO] Project path  : $project_path"
    echo "[INFO] Repo URL      : $repo_url"
    echo "--------------------------------------------------"

    rm -rf "$repo_dir"

    if ! git clone --mirror "$repo_url" "$repo_dir"; then
      echo "[WARNING] Failed to clone repository: $repo_url"

      migration_risk="UNKNOWN"
      migration_warning="Repository could not be cloned. Migration risk cannot be determined by GitSizer."
      status="FAILED_CLONE"

      write_per_repo_csv_header "$per_repo_csv"
      write_per_repo_csv_row \
        "$per_repo_csv" \
        "$repo_name" \
        "$project_path" \
        "$repo_url" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0.00" \
        "0.00" \
        "0.00" \
        "0.00" \
        "0" \
        "$THRESHOLD_MB" \
        "$migration_risk" \
        "$migration_warning" \
        "$gitsizer_json_report" \
        "$gitsizer_text_report" \
        "$per_repo_large_files_csv" \
        "$status"

      write_empty_per_repo_large_files_csv "$per_repo_large_files_csv"

      append_summary \
        "$repo_name" \
        "$project_path" \
        "$repo_url" \
        "0" \
        "0.00" \
        "0" \
        "$migration_risk" \
        "$migration_warning" \
        "$status"

      append_repo_metrics \
        "$repo_name" \
        "$project_path" \
        "$repo_url" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0" \
        "0.00" \
        "0.00" \
        "0.00" \
        "0.00" \
        "0" \
        "$THRESHOLD_MB" \
        "$migration_risk" \
        "$migration_warning" \
        "$gitsizer_json_report" \
        "$gitsizer_text_report" \
        "$per_repo_csv" \
        "$per_repo_large_files_csv" \
        "$status"

      echo "  - $repo_name  ($project_path)  URL: $repo_url" >> "$clone_failures_file"

      failed_clone_repos=$((failed_clone_repos + 1))
      continue
    fi

    repo_size_mb="$(du -sm "$repo_dir" | awk '{print $1}')"

    large_tsv="$OUT_DIR/${safe_repo_name}-large-files.tsv"
    large_tsv_abs="$ROOT_DIR/$large_tsv"

    object_details_tsv="$OUT_DIR/${safe_repo_name}-object-details.tsv"
    object_details_tsv_abs="$ROOT_DIR/$object_details_tsv"

    pushd "$repo_dir" >/dev/null

    echo "[INFO] Running git-sizer for $repo_name"

    if ! git-sizer --json > "$ROOT_DIR/$gitsizer_json_report" 2>/dev/null; then
      echo "[WARNING] git-sizer JSON output failed for $repo_name"
    fi

    if ! git-sizer > "$ROOT_DIR/$gitsizer_text_report" 2>/dev/null; then
      echo "[WARNING] git-sizer text output failed for $repo_name"
    fi

    echo "[INFO] Collecting Git object statistics"

    git rev-list --objects --all |
      git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' \
      > "$object_details_tsv_abs"

    branch_count="$(git for-each-ref --format='%(refname)' refs/heads 2>/dev/null | wc -l | tr -d ' ')"
    tag_count="$(git for-each-ref --format='%(refname)' refs/tags 2>/dev/null | wc -l | tr -d ' ')"
    remote_ref_count="$(git for-each-ref --format='%(refname)' refs/remotes 2>/dev/null | wc -l | tr -d ' ')"
    all_ref_count="$(git for-each-ref --format='%(refname)' 2>/dev/null | wc -l | tr -d ' ')"
    commit_count="$(git rev-list --all --count 2>/dev/null || echo 0)"

    read -r blob_count total_blob_bytes largest_blob_bytes tree_count total_tree_bytes largest_tree_bytes < <(
      awk '
        $1 == "blob" {
          blob_count++
          total_blob_bytes += $3
          if ($3 > largest_blob_bytes) {
            largest_blob_bytes = $3
          }
        }

        $1 == "tree" {
          tree_count++
          total_tree_bytes += $3
          if ($3 > largest_tree_bytes) {
            largest_tree_bytes = $3
          }
        }

        END {
          if (blob_count == "") blob_count = 0
          if (total_blob_bytes == "") total_blob_bytes = 0
          if (largest_blob_bytes == "") largest_blob_bytes = 0
          if (tree_count == "") tree_count = 0
          if (total_tree_bytes == "") total_tree_bytes = 0
          if (largest_tree_bytes == "") largest_tree_bytes = 0

          print blob_count, total_blob_bytes, largest_blob_bytes, tree_count, total_tree_bytes, largest_tree_bytes
        }
      ' "$object_details_tsv_abs"
    )

    total_blob_size_mb="$(bytes_to_mb "$total_blob_bytes")"
    largest_blob_mb="$(bytes_to_mb "$largest_blob_bytes")"
    total_tree_size_mb="$(bytes_to_mb "$total_tree_bytes")"
    largest_tree_mb="$(bytes_to_mb "$largest_tree_bytes")"

    echo "[INFO] Checking for blobs/files above ${THRESHOLD_MB} MB"

    awk -v threshold="$THRESHOLD_BYTES" '
      $1 == "blob" && $3 + 0 > threshold {
        path = $4

        for (i = 5; i <= NF; i++) {
          path = path " " $i
        }

        if (path == "") {
          path = "<path unavailable>"
        }

        printf "%s\t%.2f\t%s\n", $2, $3 / 1024 / 1024, path
      }
    ' "$object_details_tsv_abs" > "$large_tsv_abs"

    popd >/dev/null

    large_file_count="$(line_count "$large_tsv")"

    if [[ "$large_file_count" -gt 0 ]]; then
      migration_risk="HIGH"
      migration_warning="POTENTIAL MIGRATION FAILURE: Repository contains one or more files/blobs above ${THRESHOLD_MB} MB. Review/remove these files or migrate them using Git LFS before migration."
      status="POTENTIAL_MIGRATION_FAILURE_FILE_ABOVE_${THRESHOLD_MB}MB"

      echo
      echo "############################################################"
      echo "# POTENTIAL MIGRATION FAILURE DETECTED"
      echo "############################################################"
      echo "[WARNING] Repository : $repo_name"
      echo "[WARNING] Path       : $project_path"
      echo "[WARNING] Files > ${THRESHOLD_MB} MB : $large_file_count"
      echo "[WARNING] Largest blob        : ${largest_blob_mb} MB"
      echo "[WARNING] Risk                : HIGH"
      echo "[WARNING] Reason              : One or more files/blobs are above ${THRESHOLD_MB} MB."
      echo "[WARNING] Action              : Review large files CSV before migration."
      echo "############################################################"
      echo

      append_large_files \
        "$large_tsv" \
        "$repo_name" \
        "$project_path" \
        "$repo_url" \
        "$per_repo_large_files_csv" \
        "$migration_risk" \
        "$migration_warning" \
        "$status"

      {
        echo "----------------------------------------"
        echo "Repository : $repo_name"
        echo "Path       : $project_path"
        echo "Repo Size  : ${repo_size_mb} MB"
        echo "Largest    : ${largest_blob_mb} MB"
        echo "Risk       : HIGH"
        echo "Status     : $status"
        echo "Warning    : $migration_warning"
        echo "Files > ${THRESHOLD_MB} MB found: $large_file_count"
        echo "Per Repo CSV: $per_repo_csv"
        echo "Per Repo Large Files CSV: $per_repo_large_files_csv"
        echo "----------------------------------------"

        while IFS=$'\t' read -r blob_sha blob_size_mb file_path; do
          [[ -z "${blob_sha:-}" ]] && continue
          printf "  [WARN] %8.2f MB  %s  (blob: %s)\n" "$blob_size_mb" "$file_path" "$blob_sha"
        done < "$large_tsv"

        echo
      } >> "$warning_summary_file"

      echo "  - $repo_name  ($project_path)  Largest blob: ${largest_blob_mb} MB  Files above threshold: $large_file_count" >> "$high_risk_repos_file"

      warning_repos=$((warning_repos + 1))
      high_risk_repos=$((high_risk_repos + 1))
    else
      migration_risk="LOW"
      migration_warning="No files/blobs above ${THRESHOLD_MB} MB were found."
      status="PASSED"

      echo "[INFO] No blobs/files above ${THRESHOLD_MB} MB found"

      write_empty_per_repo_large_files_csv "$per_repo_large_files_csv"

      passed_repos=$((passed_repos + 1))
    fi

    append_summary \
      "$repo_name" \
      "$project_path" \
      "$repo_url" \
      "$repo_size_mb" \
      "$largest_blob_mb" \
      "$large_file_count" \
      "$migration_risk" \
      "$migration_warning" \
      "$status"

    write_per_repo_csv_header "$per_repo_csv"
    write_per_repo_csv_row \
      "$per_repo_csv" \
      "$repo_name" \
      "$project_path" \
      "$repo_url" \
      "$repo_size_mb" \
      "$branch_count" \
      "$tag_count" \
      "$remote_ref_count" \
      "$all_ref_count" \
      "$commit_count" \
      "$blob_count" \
      "$tree_count" \
      "$total_blob_size_mb" \
      "$largest_blob_mb" \
      "$total_tree_size_mb" \
      "$largest_tree_mb" \
      "$large_file_count" \
      "$THRESHOLD_MB" \
      "$migration_risk" \
      "$migration_warning" \
      "$gitsizer_json_report" \
      "$gitsizer_text_report" \
      "$per_repo_large_files_csv" \
      "$status"

    append_repo_metrics \
      "$repo_name" \
      "$project_path" \
      "$repo_url" \
      "$repo_size_mb" \
      "$branch_count" \
      "$tag_count" \
      "$remote_ref_count" \
      "$all_ref_count" \
      "$commit_count" \
      "$blob_count" \
      "$tree_count" \
      "$total_blob_size_mb" \
      "$largest_blob_mb" \
      "$total_tree_size_mb" \
      "$largest_tree_mb" \
      "$large_file_count" \
      "$THRESHOLD_MB" \
      "$migration_risk" \
      "$migration_warning" \
      "$gitsizer_json_report" \
      "$gitsizer_text_report" \
      "$per_repo_csv" \
      "$per_repo_large_files_csv" \
      "$status"

    rm -rf "$repo_dir"

  done < "$REPO_LIST_TSV"

  # ------------------------------------------------------------
  # Final Report
  # ------------------------------------------------------------
  {
    echo "=========================================="
    echo "GitSizer Readiness Final Report"
    echo "=========================================="
    echo "Total repositories checked          : $total_repos"
    echo "Passed repositories                 : $passed_repos"
    echo "Warning repos (> ${THRESHOLD_MB} MB files)      : $warning_repos"
    echo "High risk migration repos           : $high_risk_repos"
    echo "Failed to clone                     : $failed_clone_repos"
    echo "Summary CSV                         : $SUMMARY_CSV"
    echo "Repo Metrics CSV                    : $REPO_METRICS_CSV"
    echo "Large files CSV                     : $LARGE_FILES_CSV"
    echo "Per repo CSV directory              : $PER_REPO_CSV_DIR"
    echo "Per repo large files directory      : $PER_REPO_LARGE_FILES_DIR"
    echo "GitSizer JSON reports               : $OUT_DIR/gitsizer-json"
    echo "GitSizer text reports               : $OUT_DIR/gitsizer-text"
    echo "=========================================="

    if [[ "$high_risk_repos" -gt 0 ]]; then
      echo
      echo "=========================================="
      echo "HIGH RISK MIGRATION REPOSITORIES"
      echo "=========================================="
      echo "The following repositories contain files/blobs above ${THRESHOLD_MB} MB."
      echo "These repositories have potential migration failure risk."
      echo
      cat "$high_risk_repos_file"
    fi

    if [[ "$warning_repos" -gt 0 ]]; then
      echo
      echo "=========================================="
      echo "WARNINGS - Files above ${THRESHOLD_MB} MB found"
      echo "=========================================="
      echo "Potential migration failure warning:"
      echo "Repositories with files/blobs above ${THRESHOLD_MB} MB must be reviewed before migration."
      echo "Recommended action: remove files from history or move them to Git LFS where applicable."
      echo
      cat "$warning_summary_file"
    fi

    if [[ "$failed_clone_repos" -gt 0 ]]; then
      echo
      echo "=========================================="
      echo "CLONE FAILURES - Reported Only"
      echo "=========================================="
      echo "The following repositories could not be cloned:"
      echo
      cat "$clone_failures_file"
      echo
      echo "See log for details: $LOG_FILE"
    fi
  } | tee "$FINAL_REPORT"

  # ------------------------------------------------------------
  # Exit strategy
  # Discovery should not block migration unless every repo failed to clone.
  # ------------------------------------------------------------
  if [[ "$total_repos" -gt 0 && "$failed_clone_repos" -eq "$total_repos" ]]; then
    echo
    echo "[ERROR] All repositories failed to clone."
    echo "[ERROR] This likely indicates an inventory file or credential issue."
    echo "[ERROR] See '$FINAL_REPORT' and '$LOG_FILE' for details."
    exit 1
  fi

  echo
  echo "[INFO] GitSizer readiness check completed."

  if [[ "$high_risk_repos" -gt 0 ]]; then
    echo "[WARNING] $high_risk_repos repositor(y/ies) have potential migration failure risk due to files above ${THRESHOLD_MB} MB."
    echo "[WARNING] Review '$FINAL_REPORT', '$REPO_METRICS_CSV', and '$LARGE_FILES_CSV' before starting migration."
  fi

  if [[ "$failed_clone_repos" -gt 0 ]]; then
    echo "[WARNING] $failed_clone_repos repositor(y/ies) could not be cloned."
    echo "[WARNING] Review '$FINAL_REPORT' and '$LOG_FILE'."
  fi
}

# ------------------------------------------------------------
# Main execution
# ------------------------------------------------------------
install_git_sizer
create_repo_list
write_headers
run_checks
