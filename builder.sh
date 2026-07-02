#!/bin/bash
set -e

# --- Configuration ---
WORKSPACE_DIR="$(pwd)"
TOOLS_DIR="${WORKSPACE_DIR}/tools"
BIN_DIR="${TOOLS_DIR}/bin"

export PATH="${BIN_DIR}:${PATH}"

ARM_GCC_URL="https://developer.arm.com/-/media/Files/downloads/gnu/12.2.rel1/binrel/arm-gnu-toolchain-12.2.rel1-x86_64-arm-none-eabi.tar.xz"
ARM_GCC_DIR="${TOOLS_DIR}/arm-gcc"

XTENSA_GCC_URL="https://dl.espressif.com/dl/xtensa-lx106-elf-gcc8_4_0-esp-2020r3-linux-amd64.tar.gz"
XTENSA_GCC_DIR="${TOOLS_DIR}/xtensa-gcc"

# Repository mapping: "RepoName|BranchOrTag"
REPOS=(
    "RepRapFirmware|3.5.4"
    "CoreN2G|3.5.4"
    "FreeRTOS|3.5.4"
    "RRFLibraries|3.5.4"
    "CANlib|3.5.4"
    "DuetWiFiSocketServer|dev"
    "WiFiSocketServerRTOS|main"
)

# --- Functions ---

install_arm_gcc() {
    if [ -x "${ARM_GCC_DIR}/bin/arm-none-eabi-gcc" ]; then
        echo "[+] ARM GCC 12.2 is already extracted in tools. Restoring symlinks..."
        ln -sf "${ARM_GCC_DIR}/bin/"* "${BIN_DIR}/"
        return
    fi

    echo "[*] Installing ARM GCC 12.2 locally..."
    mkdir -p "${ARM_GCC_DIR}"

    local archive_name="arm-gcc-archive.tar.xz"
    wget -O "${TOOLS_DIR}/${archive_name}" "${ARM_GCC_URL}"

    echo "[*] Extracting ARM GCC..."
    tar -xf "${TOOLS_DIR}/${archive_name}" -C "${ARM_GCC_DIR}" --strip-components=1
    rm -f "${TOOLS_DIR}/${archive_name}"

    ln -sf "${ARM_GCC_DIR}/bin/"* "${BIN_DIR}/"
    echo "[+] ARM GCC installed successfully."
}

install_xtensa_gcc() {
    if [ -x "${XTENSA_GCC_DIR}/bin/xtensa-lx106-elf-gcc" ]; then
        echo "[+] Xtensa GCC is already extracted in tools. Restoring symlinks..."
        ln -sf "${XTENSA_GCC_DIR}/bin/"* "${BIN_DIR}/"
        return
    fi

    echo "[*] Installing Xtensa GCC locally..."
    mkdir -p "${XTENSA_GCC_DIR}"

    local archive_name="xtensa-gcc-archive.tar.gz"
    wget -O "${TOOLS_DIR}/${archive_name}" "${XTENSA_GCC_URL}"

    echo "[*] Extracting Xtensa GCC..."
    tar -xzf "${TOOLS_DIR}/${archive_name}" -C "${XTENSA_GCC_DIR}" --strip-components=1
    rm -f "${TOOLS_DIR}/${archive_name}"

    ln -sf "${XTENSA_GCC_DIR}/bin/"* "${BIN_DIR}/"
    echo "[+] Xtensa GCC installed successfully."
}

check_system_dependencies() {
    echo "[*] Checking system dependencies..."

    # Check Eclipse
    if ! command -v eclipse > /dev/null 2>&1; then
        echo "[-] Error: 'eclipse' command not found in PATH."
        echo "    Please install Eclipse CDT."
        exit 1
    else
        echo "[+] Eclipse is present."
    fi

    # Check .NET 6
    if ! command -v dotnet > /dev/null 2>&1; then
        echo "[-] Error: 'dotnet' command not found in PATH."
        echo "    Please install the .NET runtime."
        exit 1
    fi

    if ! dotnet --list-runtimes | grep -q "Microsoft.NETCore.App 6\."; then
        echo "[-] Error: .NET 6 runtime is missing."
        echo "    CrcAppender strictly requires .NET 6."
        echo "    Current runtimes installed:"
        dotnet --list-runtimes
        echo "    Please install it."
        exit 1
    else
        echo "[+] .NET 6 runtime is present."
    fi
}

check_compilers() {
    echo "[*] Checking compiler dependencies..."
    mkdir -p "${BIN_DIR}"

    # Check ARM GCC
    if ! command -v arm-none-eabi-gcc > /dev/null 2>&1; then
        echo "[-] arm-none-eabi-gcc not found in PATH."
        install_arm_gcc
    else
        local current_version=$(arm-none-eabi-gcc -dumpversion)
        if [[ ! "$current_version" =~ ^12\. ]]; then
            echo "[-] Found ARM GCC ${current_version}, but 12.x is required."
            install_arm_gcc
        else
            echo "[+] ARM GCC is present and valid (${current_version})."
        fi
    fi

    # Check Xtensa GCC
    if ! command -v xtensa-lx106-elf-gcc > /dev/null 2>&1; then
        echo "[-] xtensa-lx106-elf-gcc not found in PATH."
        install_xtensa_gcc
    else
        echo "[+] Xtensa GCC is present."
    fi
}

clone_and_checkout_repos() {
    echo "[*] Cloning and updating repositories..."

    for repo_info in "${REPOS[@]}"; do
        IFS='|' read -r repo_name target_branch <<< "$repo_info"

        if [ ! -d "$repo_name" ]; then
            echo "[*] Cloning ${repo_name}..."
            git clone "https://github.com/Duet3D/${repo_name}.git"
        fi

        echo "[*] Checking out '${target_branch}' for ${repo_name}..."
        git -C "$repo_name" fetch --all --tags --quiet

        # Resolve branch vs folder name ambiguity (e.g., ESP-IDF "main" directory)
        # Check if it's a remote branch first
        if git -C "$repo_name" show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
            git -C "$repo_name" checkout "origin/$target_branch" --quiet
        else
            # Fallback for tags (like 3.5.4) which are not under refs/remotes/
            git -C "$repo_name" checkout "$target_branch" --quiet
        fi
    done
    echo "[+] All repositories are ready."
}
setup_crcappender() {
    echo "[*] Setting up CrcAppender..."
    local crc_src="${WORKSPACE_DIR}/RepRapFirmware/Tools/CrcAppender/linux-x86_64/CrcAppender"
    local crc_dest="${BIN_DIR}/CrcAppender"

    if [ -f "$crc_src" ]; then
        chmod 755 "$crc_src"
        cp "$crc_src" "$crc_dest"
        echo "[+] CrcAppender installed to ${BIN_DIR}."
    else
        echo "[-] Error: CrcAppender source not found at ${crc_src}"
        exit 1
    fi
}

build_firmware() {
    echo "[*] Starting Eclipse headless build..."

    rm -rf .metadata # can be removed for faster build

    eclipse -nosplash \
      -application org.eclipse.cdt.managedbuilder.core.headlessbuild \
      -data . \
      -importAll . \
      -build RepRapFirmware/Duet3_MB6HC

    echo "[+] Build process completed."
}

# --- Main Execution ---

echo "=== RepRapFirmware Automated Builder ==="
check_system_dependencies
check_compilers
clone_and_checkout_repos
setup_crcappender
build_firmware
echo "=== Done ==="
