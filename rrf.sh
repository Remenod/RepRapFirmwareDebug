#!/usr/bin/env bash
#
# rrf.sh — RepRapFirmware workspace manager
#
# One entry point for setting up and building the RepRapFirmware multi-repo
# workspace. Run without arguments (or `help`) to see the available commands.
#
#   ./rrf.sh doctor              Check the environment, report what's missing
#   ./rrf.sh bootstrap           One-time setup: toolchains + repos + CrcAppender
#   ./rrf.sh build   [target]    Incremental build (default target: Duet3_MB6HC)
#   ./rrf.sh rebuild [target]    Clean build (wipes Eclipse metadata, re-imports)
#   ./rrf.sh clean               Remove build outputs and Eclipse metadata
#
set -euo pipefail

# --- Paths (resolve from this script's location, so it runs from anywhere) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$SCRIPT_DIR"
TOOLS_DIR="${WORKSPACE_DIR}/tools"
BIN_DIR="${TOOLS_DIR}/bin"
REPOS_DIR="${WORKSPACE_DIR}/repos"          # cloned Duet3D repos live here
ECLIPSE_WS="${REPOS_DIR}"                    # Eclipse workspace: holds .metadata + the imported projects

DEFAULT_TARGET="Duet3_MB6HC"

# --- Toolchains (x86_64 Linux only) ---
ARM_GCC_URL="https://developer.arm.com/-/media/Files/downloads/gnu/12.2.rel1/binrel/arm-gnu-toolchain-12.2.rel1-x86_64-arm-none-eabi.tar.xz"
ARM_GCC_DIR="${TOOLS_DIR}/arm-gcc"
ARM_GCC_BIN="arm-none-eabi-gcc"
ARM_GCC_WANT_MAJOR="12"

XTENSA_GCC_URL="https://dl.espressif.com/dl/xtensa-lx106-elf-gcc8_4_0-esp-2020r3-linux-amd64.tar.gz"
XTENSA_GCC_DIR="${TOOLS_DIR}/xtensa-gcc"
XTENSA_GCC_BIN="xtensa-lx106-elf-gcc"

# --- Repositories: name | clone-url | ref | upstream-url (upstream optional) ---
# The RepRapFirmware entry points at the personal fork + working branch so a
# fresh bootstrap reproduces this exact workspace; the others track Duet3D.
REPOS=(
    "RepRapFirmware|git@github.com:Remenod/RepRapFirmware.git|visionminer-3.5.4-debug|https://github.com/Duet3D/RepRapFirmware.git"
    "CoreN2G|https://github.com/Duet3D/CoreN2G.git|3.5.4|"
    "FreeRTOS|https://github.com/Duet3D/FreeRTOS.git|3.5.4|"
    "RRFLibraries|https://github.com/Duet3D/RRFLibraries.git|3.5.4|"
    "CANlib|https://github.com/Duet3D/CANlib.git|3.5.4|"
    "DuetWiFiSocketServer|https://github.com/Duet3D/DuetWiFiSocketServer.git|dev|"
    "WiFiSocketServerRTOS|https://github.com/Duet3D/WiFiSocketServerRTOS.git|main|"
)

# --- Pretty logging ---------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

section() { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }
info()    { printf '%s  •%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
ok()      { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s  ‼ %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()     { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET"; }
die()     { printf '\n%s✗ %s%s\n' "${C_BOLD}${C_RED}" "$*" "$C_RESET" >&2; exit 1; }

# Print the failing command/line if something unexpectedly aborts under `set -e`.
trap 's=$?; [ $s -ne 0 ] && printf "\n%s✗ Aborted (exit %s) at line %s: %s%s\n" \
    "${C_BOLD}${C_RED}" "$s" "$LINENO" "$BASH_COMMAND" "$C_RESET" >&2' ERR

have() { command -v "$1" >/dev/null 2>&1; }

# --- Environment checks -----------------------------------------------------
check_platform() {
    local os arch
    os="$(uname -s)"; arch="$(uname -m)"
    if [ "$os" != "Linux" ] || [ "$arch" != "x86_64" ]; then
        return 1
    fi
    return 0
}

arm_gcc_path()    { if [ -x "${ARM_GCC_DIR}/bin/${ARM_GCC_BIN}" ]; then echo "${ARM_GCC_DIR}/bin/${ARM_GCC_BIN}"; elif have "$ARM_GCC_BIN"; then command -v "$ARM_GCC_BIN"; fi; }
xtensa_gcc_path() { if [ -x "${XTENSA_GCC_DIR}/bin/${XTENSA_GCC_BIN}" ]; then echo "${XTENSA_GCC_DIR}/bin/${XTENSA_GCC_BIN}"; elif have "$XTENSA_GCC_BIN"; then command -v "$XTENSA_GCC_BIN"; fi; }

dotnet6_present() { have dotnet && dotnet --list-runtimes 2>/dev/null | grep -q "Microsoft.NETCore.App 6\."; }

# `doctor` — aggregate every check and report, never abort on the first failure.
cmd_doctor() {
    section "Environment check"
    local problems=0

    if check_platform; then
        ok "Platform: $(uname -s) $(uname -m)"
    else
        err "Platform: $(uname -s) $(uname -m) — toolchains are prebuilt for Linux x86_64 only"
        problems=$((problems + 1))
    fi

    # Base command-line tools required for download/extract/clone/build.
    local base_missing=()
    for c in git wget tar xz; do have "$c" || base_missing+=("$c"); done
    if [ ${#base_missing[@]} -eq 0 ]; then
        ok "Base tools: git, wget, tar, xz"
    else
        err "Base tools missing: ${base_missing[*]}  (install via your package manager)"
        problems=$((problems + 1))
    fi

    # Eclipse CDT (the actual build engine).
    if have eclipse; then ok "Eclipse CDT present"; else err "Eclipse CDT not found — install it and ensure 'eclipse' is on PATH"; problems=$((problems + 1)); fi

    # .NET 6 (CrcAppender requires exactly this runtime).
    if dotnet6_present; then
        ok ".NET 6 runtime present"
    else
        err ".NET 6 runtime missing — CrcAppender strictly requires .NET 6"
        have dotnet && info "installed: $(dotnet --list-runtimes 2>/dev/null | awk '{print $2}' | paste -sd, -)"
        problems=$((problems + 1))
    fi

    # ARM toolchain (must be 12.x).
    local ap; ap="$(arm_gcc_path || true)"
    if [ -n "$ap" ]; then
        local v; v="$("$ap" -dumpversion 2>/dev/null || echo "?")"
        if [[ "$v" == ${ARM_GCC_WANT_MAJOR}.* ]]; then ok "ARM GCC ${v}"; else warn "ARM GCC ${v} found, but ${ARM_GCC_WANT_MAJOR}.x is required — 'bootstrap' will install a local copy"; fi
    else
        warn "ARM GCC not installed — run 'bootstrap' to fetch it"
    fi

    # Xtensa toolchain (for the WiFi module).
    if [ -n "$(xtensa_gcc_path || true)" ]; then ok "Xtensa GCC present"; else warn "Xtensa GCC not installed — run 'bootstrap' to fetch it"; fi

    # Repository presence and state.
    section "Repositories"
    local repo_missing=0
    for entry in "${REPOS[@]}"; do
        IFS='|' read -r name url ref upstream <<< "$entry"
        if [ -d "${REPOS_DIR}/${name}/.git" ]; then
            local desc dirty=""
            desc="$(git -C "${REPOS_DIR}/${name}" describe --tags --always --dirty 2>/dev/null || echo '?')"
            [ -n "$(git -C "${REPOS_DIR}/${name}" status --porcelain 2>/dev/null)" ] && dirty=" ${C_YELLOW}(local changes)${C_RESET}"
            ok "${name} — ${desc}${dirty}"
        else
            err "${name} — missing (want ref '${ref}')"
            repo_missing=$((repo_missing + 1))
        fi
    done
    [ $repo_missing -gt 0 ] && problems=$((problems + 1))

    section "Summary"
    if [ $problems -eq 0 ]; then
        ok "Everything needed to build is in place."
        [ -z "$(arm_gcc_path || true)" ] && info "Run 'bootstrap' first to fetch toolchains."
        return 0
    fi
    warn "${problems} area(s) need attention (see ✗ above). 'bootstrap' fixes toolchains and repos; system packages (Eclipse, .NET 6) you install yourself."
    return 1
}

# --- Bootstrap --------------------------------------------------------------
require_for_bootstrap() {
    check_platform || die "This workspace's toolchains are prebuilt for Linux x86_64 only (found $(uname -s) $(uname -m))."
    local missing=()
    for c in git wget tar xz; do have "$c" || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] || die "Missing required tools: ${missing[*]}. Install them and re-run."
    dotnet6_present || warn ".NET 6 runtime not detected — the CrcAppender step during build will fail until you install it."
    have eclipse || warn "Eclipse CDT not detected — 'build' will fail until you install it and put 'eclipse' on PATH."
}

# Download + extract a toolchain, then verify and link its binaries.
install_toolchain() {
    local label="$1" url="$2" dir="$3" probe="$4"
    if [ -x "${dir}/bin/${probe}" ]; then
        info "${label} already extracted — refreshing symlinks"
        ln -sf "${dir}/bin/"* "${BIN_DIR}/"
        ok "${label} ready"
        return
    fi

    info "Installing ${label}…"
    mkdir -p "${dir}"
    local archive="${TOOLS_DIR}/.dl-$(echo "$label" | tr ' /' '__').archive"
    if ! wget --tries=3 --timeout=30 --continue -O "${archive}" "${url}"; then
        rm -f "${archive}"
        die "Failed to download ${label} from ${url} (check your network)."
    fi
    info "Extracting ${label}…"
    tar -xf "${archive}" -C "${dir}" --strip-components=1
    rm -f "${archive}"

    [ -x "${dir}/bin/${probe}" ] || die "${label} extracted but '${probe}' is missing — the archive layout may have changed."
    ln -sf "${dir}/bin/"* "${BIN_DIR}/"
    ok "${label} installed"
}

setup_compilers() {
    section "Toolchains"
    mkdir -p "${BIN_DIR}"

    # ARM: only reuse a system compiler if it's the required major version.
    if have "$ARM_GCC_BIN" && [[ "$($ARM_GCC_BIN -dumpversion 2>/dev/null)" == ${ARM_GCC_WANT_MAJOR}.* ]] && [ ! -x "${ARM_GCC_DIR}/bin/${ARM_GCC_BIN}" ]; then
        ok "Using system ARM GCC $($ARM_GCC_BIN -dumpversion)"
    else
        install_toolchain "ARM GCC ${ARM_GCC_WANT_MAJOR}.x" "$ARM_GCC_URL" "$ARM_GCC_DIR" "$ARM_GCC_BIN"
    fi

    if have "$XTENSA_GCC_BIN" && [ ! -x "${XTENSA_GCC_DIR}/bin/${XTENSA_GCC_BIN}" ]; then
        ok "Using system Xtensa GCC"
    else
        install_toolchain "Xtensa GCC" "$XTENSA_GCC_URL" "$XTENSA_GCC_DIR" "$XTENSA_GCC_BIN"
    fi
}

# Clone missing repos; for existing ones, fetch and report but never clobber
# local work. Pass `--sync` to fast-forward clean repos onto their pinned ref.
setup_repos() {
    local do_sync="${1:-}"
    section "Repositories"
    mkdir -p "${REPOS_DIR}"
    cd "${REPOS_DIR}"

    for entry in "${REPOS[@]}"; do
        IFS='|' read -r name url ref upstream <<< "$entry"

        if [ ! -d "${name}/.git" ]; then
            if [ -e "${name}" ]; then
                warn "${name}/ exists but is not a git repo — skipping (move it aside and re-run to clone)"
                continue
            fi
            info "Cloning ${name}…"
            git clone --quiet "${url}" "${name}"
            [ -n "$upstream" ] && git -C "${name}" remote add upstream "${upstream}" 2>/dev/null || true
            checkout_ref "${name}" "${ref}"
            ok "${name} → $(git -C "${name}" describe --tags --always 2>/dev/null)"
            continue
        fi

        # Existing repo: fetch quietly; tolerate offline.
        git -C "${name}" fetch --all --tags --quiet 2>/dev/null || warn "${name}: fetch failed (offline?) — using local state"

        if [ -n "$(git -C "${name}" status --porcelain)" ]; then
            warn "${name}: has local changes — left untouched"
            continue
        fi

        local cur; cur="$(git -C "${name}" describe --tags --always 2>/dev/null || echo '?')"
        if [ "$do_sync" = "--sync" ]; then
            checkout_ref "${name}" "${ref}"
            ok "${name} → $(git -C "${name}" describe --tags --always 2>/dev/null)"
        else
            ok "${name} present (${cur}) — not switching; pass --sync to pin to '${ref}'"
        fi
    done
}

# Check out a branch (as tracking) or a tag/commit (detached), handling the
# ESP-IDF "main is also a folder name" ambiguity by preferring remote branches.
checkout_ref() {
    local name="$1" ref="$2"
    if git -C "${name}" show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
        git -C "${name}" checkout --quiet "${ref}" 2>/dev/null || git -C "${name}" checkout --quiet -B "${ref}" "origin/${ref}"
    else
        git -C "${name}" checkout --quiet "${ref}"
    fi
}

setup_crcappender() {
    section "CrcAppender"
    local src="${REPOS_DIR}/RepRapFirmware/Tools/CrcAppender/linux-x86_64/CrcAppender"
    [ -f "$src" ] || die "CrcAppender not found at ${src} (is RepRapFirmware cloned?)."
    mkdir -p "${BIN_DIR}"
    chmod 755 "$src"
    cp "$src" "${BIN_DIR}/CrcAppender"
    ok "CrcAppender installed to tools/bin"
}

cmd_bootstrap() {
    section "Bootstrapping RepRapFirmware workspace"
    require_for_bootstrap
    setup_compilers
    setup_repos "${1:-}"
    setup_crcappender
    section "Done"
    ok "Workspace ready. Next: ${C_BOLD}./rrf.sh build${C_RESET}"
}

# --- Build ------------------------------------------------------------------
run_eclipse_build() {
    local target="$1" import="$2"
    have eclipse || die "'eclipse' not found on PATH — install Eclipse CDT (or run './rrf.sh doctor')."
    [ -d "${REPOS_DIR}/RepRapFirmware" ] || die "repos/RepRapFirmware/ is missing — run './rrf.sh bootstrap' first."
    [ -n "$(arm_gcc_path || true)" ] || die "ARM toolchain missing — run './rrf.sh bootstrap' first."

    export PATH="${BIN_DIR}:${PATH}"

    section "Building RepRapFirmware/${target}"
    info "ARM GCC: $(arm_gcc_path)"
    local args=(-nosplash -application org.eclipse.cdt.managedbuilder.core.headlessbuild -data "${ECLIPSE_WS}")
    [ "$import" = "import" ] && args+=(-importAll "${ECLIPSE_WS}")
    args+=(-build "RepRapFirmware/${target}")

    if eclipse "${args[@]}"; then
        ok "Build finished"
        report_artifacts "$target"
    else
        die "Eclipse build failed for target '${target}'."
    fi
}

report_artifacts() {
    local target="$1" newest
    # Firmware lands in a target-named output dir inside the RepRapFirmware
    # project; surface the freshest binary.
    newest="$(find "${REPOS_DIR}" -maxdepth 3 -type d -name "*${target}*" \
        -exec find {} -maxdepth 1 -name '*.bin' -printf '%T@ %p\n' \; 2>/dev/null \
        | sort -nr | head -1 | cut -d' ' -f2- || true)"
    if [ -n "$newest" ]; then
        ok "Output: ${newest} ($(du -h "$newest" | cut -f1))"
    else
        info "Build reported success; no .bin located automatically (check Eclipse output)."
    fi
}

cmd_build()   { run_eclipse_build "${1:-$DEFAULT_TARGET}" "import"; }

cmd_rebuild() {
    section "Clean rebuild"
    if [ -d "${ECLIPSE_WS}/.metadata" ]; then
        info "Removing Eclipse workspace metadata for a fresh import…"
        rm -rf "${ECLIPSE_WS}/.metadata"
    fi
    run_eclipse_build "${1:-$DEFAULT_TARGET}" "import"
}

# --- Clean ------------------------------------------------------------------
cmd_clean() {
    section "Cleaning build outputs"
    local removed=0

    # Eclipse workspace metadata (regenerated on next build), plus any stray
    # copy left at the workspace root by an older layout.
    for md in "${ECLIPSE_WS}/.metadata" "${WORKSPACE_DIR}/.metadata"; do
        if [ -d "$md" ]; then rm -rf "$md"; ok "Removed ${md#${WORKSPACE_DIR}/}"; removed=$((removed+1)); fi
    done

    # Per-target output dirs live inside the RepRapFirmware project; remove the
    # ones that actually contain build products (never touches source dirs).
    local rrf="${REPOS_DIR}/RepRapFirmware"
    if [ -d "$rrf" ]; then
        local d base
        for d in "$rrf"/*/; do
            d="${d%/}"; base="$(basename "$d")"
            if compgen -G "${d}/*.bin" >/dev/null 2>&1 || compgen -G "${d}/*.elf" >/dev/null 2>&1; then
                rm -rf "$d"; ok "Removed repos/RepRapFirmware/${base}/"; removed=$((removed+1))
            fi
        done
    fi

    [ $removed -eq 0 ] && info "Nothing to clean."
    ok "Clean complete"
}

# --- Help / dispatch --------------------------------------------------------
cmd_help() {
    cat <<EOF
${C_BOLD}rrf.sh${C_RESET} — RepRapFirmware workspace manager

${C_BOLD}Usage:${C_RESET} ./rrf.sh <command> [args]

${C_BOLD}Commands:${C_RESET}
  ${C_GREEN}doctor${C_RESET}              Check the environment and report what's missing/wrong
  ${C_GREEN}bootstrap${C_RESET} [--sync]  One-time setup: fetch toolchains, clone repos, install CrcAppender
                      (--sync also fast-forwards clean repos onto their pinned ref)
  ${C_GREEN}build${C_RESET} [target]      Incremental build            (default target: ${DEFAULT_TARGET})
  ${C_GREEN}rebuild${C_RESET} [target]    Clean build (wipe metadata, re-import, then build)
  ${C_GREEN}clean${C_RESET}               Remove build outputs and Eclipse metadata
  ${C_GREEN}help${C_RESET}                Show this message

${C_BOLD}Examples:${C_RESET}
  ./rrf.sh doctor
  ./rrf.sh bootstrap
  ./rrf.sh build
  ./rrf.sh build Duet3Mini5plus
  ./rrf.sh rebuild

${C_DIM}Toolchains install under tools/. Bootstrap never overwrites local changes in
the cloned repos — it reports them and leaves them alone.${C_RESET}
EOF
}

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        doctor|check)        cmd_doctor "$@" ;;
        bootstrap|setup|init) cmd_bootstrap "$@" ;;
        build)               cmd_build "$@" ;;
        rebuild)             cmd_rebuild "$@" ;;
        clean)               cmd_clean "$@" ;;
        help|-h|--help)      cmd_help ;;
        *) err "Unknown command: ${cmd}"; echo; cmd_help; exit 2 ;;
    esac
}

main "$@"
