WORKSPACE_DIR="$(pwd)"
TOOLS_DIR="${WORKSPACE_DIR}/tools"
BIN_DIR="${TOOLS_DIR}/bin"

export PATH="${BIN_DIR}:${PATH}"

echo $PATH

eclipse -nosplash \
        -application org.eclipse.cdt.managedbuilder.core.headlessbuild \
        -data . \
        -build RepRapFirmware/Duet3_MB6HC

echo $PATH
