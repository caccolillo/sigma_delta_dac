#!/usr/bin/env bash
# =============================================================================
# run.sh
# Bash script to run the Vitis HLS flow for the SDM CIFB 2nd-order project
#
# Usage:
#   ./run.sh
#   ./run.sh --clean        # remove project before running
#   ./run.sh --csim-only    # run C simulation only (skip synthesis)
# =============================================================================

set -e   # exit on any error
set -u   # error on undefined variables

# ----------------------------------------------------------------
#  CONFIGURATION
# ----------------------------------------------------------------
PROJECT_DIR="sdm_hls_project"
TCL_SCRIPT="run_hls.tcl"
PWL_OUTPUT="${PROJECT_DIR}/solution1/csim/build/pdm_output.pwl"
LOG_FILE="hls_run.log"

# Default Vitis HLS install location — change this if installed elsewhere
VITIS_DEFAULT="/tools/Xilinx/Vitis_HLS/2023.2"

# ----------------------------------------------------------------
#  PARSE ARGUMENTS
# ----------------------------------------------------------------
CLEAN=0
CSIM_ONLY=0
for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN=1
            ;;
        --csim-only)
            CSIM_ONLY=1
            ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--csim-only]"
            echo "  --clean       Remove project before running"
            echo "  --csim-only   Run C simulation only (faster, no synthesis)"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--clean] [--csim-only]"
            exit 1
            ;;
    esac
done

# ----------------------------------------------------------------
#  COLOURS FOR OUTPUT
# ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'   # no colour

print_header() {
    echo ""
    echo -e "${BLUE}===============================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}===============================================${NC}"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_err() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ----------------------------------------------------------------
#  CHECK FOR vitis_hls
# ----------------------------------------------------------------
print_header "Checking environment"

if ! command -v vitis_hls &> /dev/null; then
    print_warn "vitis_hls not found in PATH"

    # Try to source from default location
    if [ -f "${VITIS_DEFAULT}/settings64.sh" ]; then
        echo "Sourcing ${VITIS_DEFAULT}/settings64.sh"
        # shellcheck disable=SC1091
        source "${VITIS_DEFAULT}/settings64.sh"
    else
        print_err "Cannot find Vitis HLS installation"
        echo ""
        echo "Please source the Vitis HLS environment first, e.g.:"
        echo "  source /tools/Xilinx/Vitis_HLS/2023.2/settings64.sh"
        echo ""
        echo "Or edit VITIS_DEFAULT in this script to point to your installation."
        exit 1
    fi

    if ! command -v vitis_hls &> /dev/null; then
        print_err "vitis_hls still not found after sourcing settings"
        exit 1
    fi
fi

VITIS_VERSION=$(vitis_hls -version 2>/dev/null | head -1 || echo "unknown")
print_ok "Found vitis_hls — ${VITIS_VERSION}"

# ----------------------------------------------------------------
#  CHECK FOR REQUIRED FILES
# ----------------------------------------------------------------
REQUIRED_FILES=(
    "sdm_cifb_2nd.h"
    "sdm_cifb_2nd.cpp"
    "sdm_cifb_2nd_tb.cpp"
    "${TCL_SCRIPT}"
)

for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        print_err "Required file not found: $f"
        exit 1
    fi
done
print_ok "All source files present"

# ----------------------------------------------------------------
#  CLEAN IF REQUESTED
# ----------------------------------------------------------------
if [ $CLEAN -eq 1 ]; then
    print_header "Cleaning previous project"
    if [ -d "${PROJECT_DIR}" ]; then
        rm -rf "${PROJECT_DIR}"
        print_ok "Removed ${PROJECT_DIR}"
    fi
    if [ -f "${LOG_FILE}" ]; then
        rm -f "${LOG_FILE}"
        print_ok "Removed ${LOG_FILE}"
    fi
    if [ -f "vitis_hls.log" ]; then
        rm -f vitis_hls.log
    fi
fi

# ----------------------------------------------------------------
#  PREPARE TCL SCRIPT FOR CSIM-ONLY MODE
# ----------------------------------------------------------------
if [ $CSIM_ONLY -eq 1 ]; then
    print_header "Creating csim-only TCL script"
    TCL_SCRIPT_RUN="run_hls_csim_only.tcl"
    cat > "${TCL_SCRIPT_RUN}" <<'EOF'
open_project -reset sdm_hls_project
set_top sdm_cifb_2nd
add_files sdm_cifb_2nd.cpp -cflags "-std=c++14"
add_files -tb sdm_cifb_2nd_tb.cpp -cflags "-std=c++14"
open_solution -reset "solution1" -flow_target vivado
set_part {xc7a35tcpg236-1}
create_clock -period 10 -name default
csim_design
exit
EOF
    print_ok "Created ${TCL_SCRIPT_RUN}"
else
    TCL_SCRIPT_RUN="${TCL_SCRIPT}"
fi

# ----------------------------------------------------------------
#  RUN VITIS HLS
# ----------------------------------------------------------------
print_header "Running Vitis HLS"
echo "Script:   ${TCL_SCRIPT_RUN}"
echo "Log file: ${LOG_FILE}"
echo ""

START_TIME=$(date +%s)

if vitis_hls -f "${TCL_SCRIPT_RUN}" 2>&1 | tee "${LOG_FILE}"; then
    HLS_STATUS=0
else
    HLS_STATUS=$?
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# ----------------------------------------------------------------
#  REPORT RESULTS
# ----------------------------------------------------------------
print_header "Summary"

echo "Elapsed time: ${ELAPSED} seconds"
echo ""

if [ ${HLS_STATUS} -ne 0 ]; then
    print_err "Vitis HLS exited with status ${HLS_STATUS}"
    echo "Check ${LOG_FILE} for details"
    exit ${HLS_STATUS}
fi

# Check for the PWL file
if [ -f "${PWL_OUTPUT}" ]; then
    PWL_SIZE=$(du -h "${PWL_OUTPUT}" | cut -f1)
    PWL_LINES=$(wc -l < "${PWL_OUTPUT}")
    print_ok "PWL file generated: ${PWL_OUTPUT}"
    echo "       Size:  ${PWL_SIZE}"
    echo "       Lines: ${PWL_LINES}"

    # Copy to current directory for easy access
    cp "${PWL_OUTPUT}" ./pdm_output.pwl
    print_ok "Copied to ./pdm_output.pwl"
else
    print_warn "PWL file not found at expected location"
fi

# Check for synthesised RTL (if not csim-only)
if [ $CSIM_ONLY -eq 0 ]; then
    RTL_DIR="${PROJECT_DIR}/solution1/syn/verilog"
    IP_DIR="${PROJECT_DIR}/solution1/impl/ip"

    if [ -d "${RTL_DIR}" ]; then
        RTL_FILES=$(find "${RTL_DIR}" -name '*.v' | wc -l)
        print_ok "Verilog RTL: ${RTL_DIR} (${RTL_FILES} files)"
    fi

    if [ -d "${IP_DIR}" ]; then
        print_ok "Packaged IP: ${IP_DIR}"
    fi

    # Quick synthesis report
    SYN_RPT="${PROJECT_DIR}/solution1/syn/report/sdm_cifb_2nd_csynth.rpt"
    if [ -f "${SYN_RPT}" ]; then
        print_ok "Synthesis report: ${SYN_RPT}"
        echo ""
        echo "--- Resource summary ---"
        # Extract the LUT/FF/DSP/BRAM line
        grep -E '^\|Total' "${SYN_RPT}" | head -1 || true
        echo ""
    fi
fi

print_header "Done"
echo ""
echo "Next steps:"
echo "  1. Open LTspice"
echo "  2. Place a voltage source, right-click → Advanced → PWL FILE"
echo "  3. Browse to: $(pwd)/pdm_output.pwl"
echo "  4. Build your RC filter and run .tran 0 25m"
echo ""

exit 0
