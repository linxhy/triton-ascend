#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/config/versions.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/config/versions.env"
elif [[ -f /etc/triton-builder/versions.env ]]; then
  # shellcheck disable=SC1091
  source /etc/triton-builder/versions.env
fi

: "${SOURCE_URL:=https://gitcode.com/Ascend/Triton-distributed-ascend.git}"
: "${SEED_LLVM_COMMIT:=f6ded0be897e2878612dd903f7e8bb85448269e5}"

SOURCE_PATH=''
SOURCE_REF=''
OUTPUT_DIR=/workspace/output
WORK_DIR=/workspace/work
CACHE_DIR=/workspace/cache
JOBS=''
KEEP_WORK=0
ATTEMPT_ID=''
ATTEMPT_DIR=''
BUILD_SOURCE=''
LOG_DIR=''
ATTEMPT_OUTPUT=''
CURRENT_STAGE=initialization
LLVM_PREFIX=''
LLVM_COMMIT=''
ASCEND_IR_ROOT=''
STARTED_AT=''
SOURCE_COMMIT=''

usage() {
  cat <<'EOF'
Usage: build-triton-distributed-ascend [OPTIONS]

Build shmem and triton_dist wheels from Triton-distributed-ascend source.

Options:
  --source PATH     Build from a disposable copy of an existing source tree.
  --ref REF         Branch, tag, or commit to check out when cloning source.
  --output PATH     Output directory (default: /workspace/output).
  --work-dir PATH   Disposable work directory (default: /workspace/work).
  --cache-dir PATH  Persistent LLVM/pip/ccache cache (default: /workspace/cache).
  --jobs N          Initial parallel build jobs (default: min(nproc, 128)).
  --keep-work       Keep the attempt work directory after a successful build.
  --help            Show this help and exit.
EOF
}

die() {
  local message=${1:-'unknown error'}
  local exit_code=${2:-1}
  printf 'ERROR: %s\n' "$message" >&2
  exit "$exit_code"
}

require_value() {
  local option=$1 count=$2
  (( count >= 2 )) || die "$option requires a value" 2
}

parse_args() {
  while (($#)); do
    case "$1" in
      --source)
        require_value "$1" "$#"; SOURCE_PATH=$2; shift 2 ;;
      --ref)
        require_value "$1" "$#"; SOURCE_REF=$2; shift 2 ;;
      --output)
        require_value "$1" "$#"; OUTPUT_DIR=$2; shift 2 ;;
      --work-dir)
        require_value "$1" "$#"; WORK_DIR=$2; shift 2 ;;
      --cache-dir)
        require_value "$1" "$#"; CACHE_DIR=$2; shift 2 ;;
      --jobs)
        require_value "$1" "$#"; JOBS=$2; shift 2 ;;
      --keep-work)
        KEEP_WORK=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        die "unknown option: $1" 2 ;;
    esac
  done

  if [[ -n "$JOBS" && ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    die '--jobs must be a positive integer' 2
  fi
  if [[ -n "$SOURCE_PATH" && ! -d "$SOURCE_PATH" ]]; then
    die "source directory does not exist: $SOURCE_PATH" 2
  fi
}

init_paths() {
  if [[ -z "$JOBS" ]]; then
    local detected
    detected=$(nproc 2>/dev/null || printf '1')
    (( detected > 128 )) && detected=128
    JOBS=$detected
  fi
  ATTEMPT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  ATTEMPT_DIR="$WORK_DIR/attempt-$ATTEMPT_ID"
  BUILD_SOURCE="$ATTEMPT_DIR/source/Triton-distributed-ascend"
  LOG_DIR="$OUTPUT_DIR/logs/$ATTEMPT_ID"
  ATTEMPT_OUTPUT="$ATTEMPT_DIR/output"
  STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
}

record_event() {
  local stage=$1 status=$2 detail=${3:-}
  [[ -n "$LOG_DIR" ]] || return 0
  mkdir -p "$LOG_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" "$status" "$detail" \
    >>"$LOG_DIR/timeline.tsv"
}

on_error() {
  local rc=$?
  record_event "$CURRENT_STAGE" failed "exit_code=$rc"
  if declare -F write_result_json >/dev/null && [[ -n "$OUTPUT_DIR" ]]; then
    write_result_json failed "$rc" 2>/dev/null || true
  fi
  printf 'ERROR: stage=%s exit_code=%s\n' "$CURRENT_STAGE" "$rc" >&2
  exit "$rc"
}

cleanup() {
  local rc=$?
  if (( rc == 0 && KEEP_WORK == 0 )) && [[ -n "$ATTEMPT_DIR" && -d "$ATTEMPT_DIR" ]]; then
    rm -rf -- "$ATTEMPT_DIR"
  fi
}

print_plan() {
  printf 'source=%s\n' "${SOURCE_PATH:-auto:$SOURCE_URL${SOURCE_REF:+@$SOURCE_REF}}"
  printf 'build_source=%s\n' "$BUILD_SOURCE"
  printf 'output=%s\n' "$OUTPUT_DIR"
  printf 'work_dir=%s\n' "$WORK_DIR"
  printf 'cache_dir=%s\n' "$CACHE_DIR"
  printf 'jobs=%s\n' "$JOBS"
  printf 'keep_work=%s\n' "$KEEP_WORK"
}

resolve_llvm_commit() {
  local source_root=$1
  local hash_file="$source_root/3rdparty/triton-ascend/cmake/llvm-hash.txt"
  [[ -f "$hash_file" ]] || return 1
  local commit
  commit=$(tr -d '[:space:]' <"$hash_file")
  [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  printf '%s\n' "${commit,,}"
}

resolve_ascend_ir_submodule_path() {
  local triton_root=$1
  [[ -f "$triton_root/.gitmodules" ]] || return 1
  awk -F= '
    /^[[:space:]]*path[[:space:]]*=/ {
      value=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /(^|\/)AscendNPU-IR$/) {
        print value
        found=1
        exit
      }
    }
    END {if (!found) exit 1}
  ' "$triton_root/.gitmodules"
}

find_llvm_patch() {
  local source_root=$1 commit=$2
  local patch_dir="$source_root/3rdparty/triton-ascend/third_party/ascend/patch"
  local short=${commit:0:7}
  local candidate
  for candidate in \
    "$patch_dir/llvm_patch_${short}.patch" \
    "$patch_dir/llvm_patch_${commit}.patch"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

llvm_patch_sha() {
  local source_root=$1 commit=$2 patch
  if patch=$(find_llvm_patch "$source_root" "$commit"); then
    sha256sum "$patch" | awk '{print $1}'
  else
    printf 'none\n'
  fi
}

write_llvm_stamp() {
  local prefix=$1 commit=$2 patch_sha=$3
  mkdir -p "$prefix"
  cat >"$prefix/.triton-builder-stamp" <<EOF
llvm_commit=$commit
patch_sha256=$patch_sha
configure_version=1
EOF
}

llvm_cache_valid() {
  local prefix=$1 commit=$2 patch_sha=$3
  local stamp="$prefix/.triton-builder-stamp"
  [[ -x "$prefix/bin/llvm-config" ]] || return 1
  [[ -x "$prefix/bin/FileCheck" ]] || return 1
  [[ -x "$prefix/bin/llvm-lit" ]] || return 1
  [[ -f "$prefix/lib/cmake/llvm/LLVMConfig.cmake" ]] || return 1
  [[ -f "$stamp" ]] || return 1
  grep -Fxq "llvm_commit=$commit" "$stamp" || return 1
  grep -Fxq "patch_sha256=$patch_sha" "$stamp" || return 1
  grep -Fxq 'configure_version=1' "$stamp" || return 1
}

retry_jobs() {
  local initial=$1 candidate
  local -a values=("$initial")
  for candidate in 64 32 16; do
    (( candidate < initial )) && values+=("$candidate")
  done
  printf '%s\n' "${values[*]}"
}

safe_rm_tree() {
  local target=$1 allowed_root=$2
  local resolved_target resolved_root
  resolved_target=$(realpath -m "$target")
  resolved_root=$(realpath -m "$allowed_root")
  [[ "$resolved_target" == "$resolved_root/"* ]] || die "refusing to remove path outside $resolved_root: $resolved_target"
  [[ "$resolved_target" != "$resolved_root" ]] || die "refusing to remove cache root: $resolved_root"
  rm -rf -- "$resolved_target"
}

build_llvm() {
  local commit=$1 prefix=$2 source_root=$3 jobs=$4
  local source_dir="$CACHE_DIR/sources/llvm-$commit"
  local build_dir="$CACHE_DIR/build/llvm-$commit"
  local archive="$CACHE_DIR/downloads/llvm-project-$commit.tar.gz"
  local temp_prefix="${prefix}.tmp.$$"
  local patch=''

  mkdir -p "$CACHE_DIR/downloads" "$CACHE_DIR/sources" "$CACHE_DIR/build"
  if [[ ! -s "$archive" ]]; then
    curl -fL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 1800 \
      -o "$archive.part" "https://codeload.github.com/llvm/llvm-project/tar.gz/$commit"
    gzip -t "$archive.part"
    mv "$archive.part" "$archive"
  fi

  safe_rm_tree "$source_dir" "$CACHE_DIR"
  safe_rm_tree "$build_dir" "$CACHE_DIR"
  safe_rm_tree "$temp_prefix" "$CACHE_DIR"
  mkdir -p "$source_dir" "$build_dir" "$temp_prefix"
  tar -xzf "$archive" --strip-components=1 -C "$source_dir"

  if patch=$(find_llvm_patch "$source_root" "$commit"); then
    (cd "$source_dir" && git apply --check "$patch" && git apply "$patch")
  fi

  cmake -S "$source_dir/llvm" -B "$build_dir" -G Ninja \
    -DCMAKE_C_COMPILER=/usr/bin/clang \
    -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_LINKER=/usr/bin/ld.lld \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    '-DLLVM_ENABLE_PROJECTS=mlir;llvm;lld' \
    '-DLLVM_TARGETS_TO_BUILD=host;NVPTX;AMDGPU' \
    -DLLVM_ENABLE_LLD=ON \
    -DCMAKE_INSTALL_PREFIX="$temp_prefix"
  cmake --build "$build_dir" --target install --parallel "$jobs"
  install -m 0755 "$build_dir/bin/FileCheck" "$temp_prefix/bin/FileCheck"
  install -m 0755 "$build_dir/bin/llvm-lit" "$temp_prefix/bin/llvm-lit"
  write_llvm_stamp "$temp_prefix" "$commit" "$(llvm_patch_sha "$source_root" "$commit")"
  safe_rm_tree "$prefix" "$CACHE_DIR"
  mv "$temp_prefix" "$prefix"
}

pipeline_stage_list() {
  printf '%s\n' 'prepare_source resolve_llvm build_ascendnpu_ir build_shmem materialize_triton_backends build_triton_wheel verify_wheels'
}

retry_network() {
  local attempt rc=1
  for attempt in 1 2 3 4 5; do
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    printf 'network attempt %d/5 failed (exit=%d)\n' "$attempt" "$rc" >&2
    (( attempt == 5 )) || sleep "$((attempt * 2))"
  done
  return "$rc"
}

load_build_env() {
  : "${LD_LIBRARY_PATH:=}"
  : "${PYTHONPATH:=}"
  : "${CMAKE_PREFIX_PATH:=}"
  export LD_LIBRARY_PATH PYTHONPATH CMAKE_PREFIX_PATH
  if [[ -f /usr/local/Ascend/cann/set_env.sh ]]; then
    # shellcheck disable=SC1091
    source /usr/local/Ascend/cann/set_env.sh
  elif [[ -f /usr/local/Ascend/ascend-toolkit/set_env.sh ]]; then
    # shellcheck disable=SC1091
    source /usr/local/Ascend/ascend-toolkit/set_env.sh
  else
    die 'CANN set_env.sh was not found'
  fi
  if [[ -f /opt/triton-build-venv/bin/activate ]]; then
    # shellcheck disable=SC1091
    source /opt/triton-build-venv/bin/activate
  fi
  local build_venv=${VIRTUAL_ENV:-/opt/triton-build-venv}
  export PATH="$build_venv/bin:/usr/bin:/bin:$PATH"
  export TORCH_DEVICE_BACKEND_AUTOLOAD=0
  export CCACHE_DIR="$CACHE_DIR/ccache"
  export PIP_CACHE_DIR="$CACHE_DIR/pip"
  mkdir -p "$CCACHE_DIR" "$PIP_CACHE_DIR"
  hash -r
}

prepare_source() {
  mkdir -p "$(dirname "$BUILD_SOURCE")" "$ATTEMPT_OUTPUT" "$LOG_DIR" "$CACHE_DIR"
  if [[ -n "$SOURCE_PATH" ]]; then
    git -C "$SOURCE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
      die 'the supplied source must be a Git working tree'
    local supplied_commit
    supplied_commit=$(git -C "$SOURCE_PATH" rev-parse HEAD)
    git clone --no-local --no-checkout "$SOURCE_PATH" "$BUILD_SOURCE"
    git -C "$BUILD_SOURCE" checkout --detach "$supplied_commit"
  else
    retry_network git -c http.version=HTTP/1.1 clone --filter=blob:none "$SOURCE_URL" "$BUILD_SOURCE"
    if [[ -n "$SOURCE_REF" ]]; then
      retry_network git -C "$BUILD_SOURCE" -c http.version=HTTP/1.1 fetch --depth=1 origin "$SOURCE_REF"
      git -C "$BUILD_SOURCE" checkout --detach FETCH_HEAD
    fi
  fi

  [[ -f "$BUILD_SOURCE/.gitmodules" ]] || die 'source is missing .gitmodules'
  SOURCE_COMMIT=$(git -C "$BUILD_SOURCE" rev-parse HEAD)
  retry_network git -C "$BUILD_SOURCE" -c http.version=HTTP/1.1 submodule update --init --depth=1 \
    3rdparty/triton-ascend 3rdparty/shmem
  retry_network git -C "$BUILD_SOURCE/3rdparty/shmem" -c http.version=HTTP/1.1 \
    submodule update --init --recursive --depth=1

  local triton_root="$BUILD_SOURCE/3rdparty/triton-ascend"
  local ir_relative nested_ir
  ir_relative=$(resolve_ascend_ir_submodule_path "$triton_root") || \
    die 'triton-ascend does not declare an AscendNPU-IR submodule'
  nested_ir="$triton_root/$ir_relative"
  retry_network git -C "$triton_root" -c http.version=HTTP/1.1 \
    submodule update --init --depth=1 "$ir_relative"
  retry_network git -C "$nested_ir" -c http.version=HTTP/1.1 \
    submodule update --init --depth=1
  ASCEND_IR_ROOT=$nested_ir
  [[ -n "$ASCEND_IR_ROOT" && -x "$ASCEND_IR_ROOT/build-tools/build.sh" ]] || \
    die 'source-pinned AscendNPU-IR build script was not found'

  {
    printf 'main=%s\n' "$SOURCE_COMMIT"
    printf 'triton_ascend=%s\n' "$(git -C "$BUILD_SOURCE/3rdparty/triton-ascend" rev-parse HEAD)"
    printf 'shmem=%s\n' "$(git -C "$BUILD_SOURCE/3rdparty/shmem" rev-parse HEAD)"
    printf 'ascend_npu_ir=%s\n' "$(git -C "$ASCEND_IR_ROOT" rev-parse HEAD)"
    printf 'submodules_begin\n'
    git -C "$BUILD_SOURCE" submodule status
    printf 'submodules_end\n'
  } >"$OUTPUT_DIR/source-versions.txt"
}

run_stage_with_jobs() {
  local stage=$1 callback=$2 jobs rc log
  for jobs in $(retry_jobs "$JOBS"); do
    log="$LOG_DIR/${stage}-j${jobs}.log"
    record_event "$stage" started "jobs=$jobs log=$log"
    if (ATTEMPT_JOBS=$jobs; export ATTEMPT_JOBS; "$callback") > >(tee "$log") 2>&1; then
      rc=0
    else
      rc=$?
    fi
    if (( rc == 0 )); then
      record_event "$stage" succeeded "jobs=$jobs"
      return 0
    fi
    record_event "$stage" failed "jobs=$jobs exit_code=$rc"
  done
  return "$rc"
}

resolve_llvm_stage() {
  LLVM_COMMIT=$(resolve_llvm_commit "$BUILD_SOURCE") || die 'invalid source-declared LLVM hash'
  local patch_sha seed_prefix dynamic_prefix
  patch_sha=$(llvm_patch_sha "$BUILD_SOURCE" "$LLVM_COMMIT")
  seed_prefix="/opt/llvm-cache/$LLVM_COMMIT"
  dynamic_prefix="$CACHE_DIR/llvm/$LLVM_COMMIT"

  if llvm_cache_valid "$seed_prefix" "$LLVM_COMMIT" "$patch_sha"; then
    LLVM_PREFIX=$seed_prefix
    record_event resolve_llvm cache_hit "prefix=$LLVM_PREFIX"
  elif llvm_cache_valid "$dynamic_prefix" "$LLVM_COMMIT" "$patch_sha"; then
    LLVM_PREFIX=$dynamic_prefix
    record_event resolve_llvm cache_hit "prefix=$LLVM_PREFIX"
  else
    LLVM_PREFIX=$dynamic_prefix
    run_stage_with_jobs llvm "build_llvm_callback"
  fi
  export LLVM_SYSPATH=$LLVM_PREFIX
  "$LLVM_PREFIX/bin/llvm-config" --version
  "$LLVM_PREFIX/bin/FileCheck" --version
  PYTHONPATH="/opt/triton-build-venv/lib64/python3.11/site-packages:/opt/triton-build-venv/lib/python3.11/site-packages:${PYTHONPATH:-}" \
    "$LLVM_PREFIX/bin/llvm-lit" --version
  printf 'llvm_commit=%s\nllvm_prefix=%s\npatch_sha256=%s\n' \
    "$LLVM_COMMIT" "$LLVM_PREFIX" "$patch_sha" >"$OUTPUT_DIR/llvm-version.txt"
}

build_llvm_callback() {
  build_llvm "$LLVM_COMMIT" "$LLVM_PREFIX" "$BUILD_SOURCE" "$ATTEMPT_JOBS"
}

detect_bisheng_compiler_option() {
  local help_text=$1
  if grep -Fq -- '--bisheng-compiler' <<<"$help_text"; then
    printf '%s\n' '--bisheng-compiler'
  elif grep -Fq -- '--bisheng-compile' <<<"$help_text"; then
    printf '%s\n' '--bisheng-compile'
  else
    return 1
  fi
}

read_ascend_ir_build_help() {
  local ir_root=$1
  (cd "$ir_root" && bash build-tools/build.sh --help 2>&1)
}

build_ascendnpu_ir() {
  local compiler_option help_text
  help_text=$(read_ascend_ir_build_help "$ASCEND_IR_ROOT" || true)
  compiler_option=$(detect_bisheng_compiler_option "$help_text") || \
    die 'AscendNPU-IR build script has no supported BiSheng compiler option'
  safe_rm_tree "$ASCEND_IR_ROOT/build" "$ATTEMPT_DIR"
  (
    cd "$ASCEND_IR_ROOT"
    timeout --signal=TERM 7200 bash build-tools/build.sh \
      -o ./build -t --build-type Release --apply-patches \
      "$compiler_option=$ASCEND_HOME_PATH/bin" \
      --build-shmem-template -j "$ATTEMPT_JOBS"
  )
  [[ -x "$ASCEND_IR_ROOT/build/bin/bishengir-compile" ]] || \
    die 'AscendNPU-IR build did not produce bishengir-compile'
}

build_shmem() {
  local root="$BUILD_SOURCE/3rdparty/shmem" wheel
  (
    cd "$root"
    MAX_JOBS="$ATTEMPT_JOBS" timeout --signal=TERM 7200 bash scripts/build.sh -python_extension
  )
  wheel=$(find "$root" -type f -name 'shmem-*.whl' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
  [[ -n "$wheel" && -f "$wheel" ]] || die 'shmem build completed without a wheel'
  rm -f "$ATTEMPT_OUTPUT"/shmem-*.whl
  cp -a "$wheel" "$ATTEMPT_OUTPUT/"
}

materialize_triton_backends() {
  local root=${1:-$BUILD_SOURCE}
  local python_root="$root/python"
  local triton_root="$root/3rdparty/triton-ascend"
  local repository_patch="$root/3rdparty/triton-ascend.patch"
  local python_bin=python
  command -v "$python_bin" >/dev/null 2>&1 || python_bin=python3
  [[ -f "$python_root/setup.py" ]] || die 'source is missing python/setup.py'
  if git -C "$triton_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$triton_root" restore --worktree --source=HEAD -- .
    if [[ -s "$repository_patch" ]]; then
      git -C "$triton_root" apply --check "$repository_patch"
      git -C "$triton_root" apply "$repository_patch"
    fi
  fi
  export LLVM_SYSPATH=$LLVM_PREFIX
  export PATH="$ASCEND_IR_ROOT/build/bin:$PATH"
  (
    cd "$python_root"
    "$python_bin" - <<'PY'
import runpy
import setuptools

original_setup = setuptools.setup
setuptools.setup = lambda *args, **kwargs: None
try:
    namespace = runpy.run_path("setup.py", run_name="__triton_builder_setup__")
finally:
    setuptools.setup = original_setup

add_links = namespace.get("add_links")
if not callable(add_links):
    raise RuntimeError("upstream setup.py does not expose add_links")
add_links(external_only=False, materialization=False)
PY
  )
  [[ -f "$python_root/triton/backends/ascend/__init__.py" ]] || \
    die 'upstream add_links did not materialize the Ascend backend'
}

build_triton_wheel() {
  local root=$BUILD_SOURCE
  export LLVM_SYSPATH=$LLVM_PREFIX
  export PATH="$ASCEND_IR_ROOT/build/bin:$PATH"
  safe_rm_tree "$root/python/build" "$ATTEMPT_DIR"
  safe_rm_tree "$root/python/triton_dist.egg-info" "$ATTEMPT_DIR"
  rm -f "$ATTEMPT_OUTPUT"/triton_dist-*.whl
  (
    cd "$root"
    LLVM_SYSPATH="$LLVM_PREFIX" \
    TRITON_USE_ASCEND=ON \
    TRITON_OFFLINE_BUILD=ON \
    TRITON_BUILD_WITH_CLANG_LLD=ON \
    TRITON_BUILD_PROTON=OFF \
    TRITON_BUILD_LITTLE_KERNEL=OFF \
    MAX_JOBS="$ATTEMPT_JOBS" \
    timeout --signal=TERM 7200 python -m pip wheel ./python --no-build-isolation -w "$ATTEMPT_OUTPUT"
  )
}

verify_wheel_archive() {
  local wheel=$1 family=$2
  [[ -f "$wheel" ]] || return 1
  [[ "$(basename "$wheel")" == "$family"-*-cp311-cp311-linux_aarch64.whl ]] || return 1
  WHEEL_PATH="$wheel" WHEEL_FAMILY="$family" python3 - <<'PY'
import os
import sys
import zipfile

path = os.environ["WHEEL_PATH"]
family = os.environ["WHEEL_FAMILY"]
try:
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("corrupt member")
        names = archive.namelist()
        if not any(name.endswith(".dist-info/WHEEL") for name in names):
            raise ValueError("missing WHEEL metadata")
        if family == "triton_dist" and not any(
            name.startswith("triton/backends/ascend/") for name in names
        ):
            raise ValueError("missing Ascend backend")
except (OSError, ValueError, zipfile.BadZipFile) as exc:
    print(f"wheel verification failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

verify_wheel_elfs() {
  local wheel=$1 extract_dir=$2 count=0 elf
  mkdir -p "$extract_dir"
  WHEEL_PATH="$wheel" EXTRACT_DIR="$extract_dir" python3 - <<'PY'
import os
import zipfile
with zipfile.ZipFile(os.environ["WHEEL_PATH"]) as archive:
    archive.extractall(os.environ["EXTRACT_DIR"])
PY
  while IFS= read -r -d '' elf; do
    if file "$elf" | grep -q 'ELF '; then
      readelf -h "$elf" | grep -Eq 'Machine:[[:space:]]+AArch64' || return 1
      count=$((count + 1))
    fi
  done < <(find "$extract_dir" -type f \( -name '*.so' -o -name '*.so.*' \) -print0)
  (( count > 0 )) || return 1
}

verify_wheels() {
  local -a shmem_wheels=("$ATTEMPT_OUTPUT"/shmem-*.whl)
  local -a triton_wheels=("$ATTEMPT_OUTPUT"/triton_dist-*.whl)
  (( ${#shmem_wheels[@]} == 1 )) && [[ -f "${shmem_wheels[0]}" ]] || die 'expected exactly one shmem wheel'
  (( ${#triton_wheels[@]} == 1 )) && [[ -f "${triton_wheels[0]}" ]] || die 'expected exactly one triton_dist wheel'
  verify_wheel_archive "${shmem_wheels[0]}" shmem
  verify_wheel_archive "${triton_wheels[0]}" triton_dist
  verify_wheel_elfs "${shmem_wheels[0]}" "$ATTEMPT_DIR/verify/shmem"
  verify_wheel_elfs "${triton_wheels[0]}" "$ATTEMPT_DIR/verify/triton_dist"

  python -m venv "$ATTEMPT_DIR/verify-venv"
  "$ATTEMPT_DIR/verify-venv/bin/python" -m pip install --no-deps \
    "${shmem_wheels[0]}" "${triton_wheels[0]}"
  "$ATTEMPT_DIR/verify-venv/bin/python" -m pip show shmem triton-dist >/dev/null

  mkdir -p "$OUTPUT_DIR"
  cp -a "${shmem_wheels[0]}" "${triton_wheels[0]}" "$OUTPUT_DIR/"
  (cd "$OUTPUT_DIR" && sha256sum ./*.whl >SHA256SUMS && sha256sum -c SHA256SUMS)
}

write_result_json() {
  local status=$1 exit_code=${2:-0}
  local finished_at
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$OUTPUT_DIR"
  RESULT_STATUS="$status" RESULT_EXIT_CODE="$exit_code" RESULT_STARTED_AT="$STARTED_AT" \
  RESULT_FINISHED_AT="$finished_at" RESULT_SOURCE="$SOURCE_COMMIT" RESULT_LLVM="$LLVM_COMMIT" \
  RESULT_OUTPUT="$OUTPUT_DIR" python3 - <<'PY' >"$OUTPUT_DIR/build-result.json"
import json
import os
from pathlib import Path

output = Path(os.environ["RESULT_OUTPUT"])
wheels = []
for path in sorted(output.glob("*.whl")):
    wheels.append({"name": path.name, "size": path.stat().st_size})
result = {
    "schema_version": 1,
    "status": os.environ["RESULT_STATUS"],
    "exit_code": int(os.environ["RESULT_EXIT_CODE"]),
    "started_at": os.environ["RESULT_STARTED_AT"],
    "finished_at": os.environ["RESULT_FINISHED_AT"],
    "source_commit": os.environ["RESULT_SOURCE"],
    "llvm_commit": os.environ["RESULT_LLVM"],
    "artifacts": wheels,
    "runtime_validation": {
        "status": "skipped_environment_unavailable",
        "reason": "NPU devices, driver, npu-smi, or HCCL may be unavailable",
    },
}
print(json.dumps(result, ensure_ascii=False, indent=2))
PY
}

main() {
  parse_args "$@"
  init_paths
  if [[ ${BUILDER_TEST_MODE:-} == plan ]]; then
    print_plan
    return 0
  fi
  trap on_error ERR
  trap cleanup EXIT
  mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$ATTEMPT_DIR"
  record_event initialization started "attempt=$ATTEMPT_ID"
  load_build_env

  CURRENT_STAGE=prepare_source
  prepare_source > >(tee "$LOG_DIR/prepare-source.log") 2>&1
  record_event prepare_source succeeded

  CURRENT_STAGE=resolve_llvm
  resolve_llvm_stage > >(tee "$LOG_DIR/resolve-llvm.log") 2>&1
  record_event resolve_llvm succeeded "commit=$LLVM_COMMIT prefix=$LLVM_PREFIX"

  CURRENT_STAGE=build_ascendnpu_ir
  run_stage_with_jobs build-ascendnpu-ir build_ascendnpu_ir

  CURRENT_STAGE=build_shmem
  run_stage_with_jobs build-shmem build_shmem

  CURRENT_STAGE=materialize_triton_backends
  materialize_triton_backends "$BUILD_SOURCE" > >(tee "$LOG_DIR/materialize-triton-backends.log") 2>&1
  record_event materialize_triton_backends succeeded

  CURRENT_STAGE=build_triton_wheel
  run_stage_with_jobs build-triton-wheel build_triton_wheel

  CURRENT_STAGE=verify_wheels
  verify_wheels > >(tee "$LOG_DIR/verify-wheels.log") 2>&1
  record_event verify_wheels succeeded
  write_result_json success 0
  record_event complete succeeded
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
