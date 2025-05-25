#!/bin/bash

# Colored output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
NC='\033[0m'  

# Force unlimited memlock if possible
CURRENT_MEMLOCK=$(ulimit -l)
if [[ "$CURRENT_MEMLOCK" != "unlimited" ]]; then
    ulimit -l unlimited 2>/dev/null
    if [[ "$(ulimit -l)" != "unlimited" ]]; then
        echo -e "${YELLOW}⚠️  Warning: could not set ulimit -l unlimited (current: $CURRENT_MEMLOCK). You may encounter mlock errors.${NC}"
    else
        echo -e "${GREEN}🔓 memlock limit set to unlimited.${NC}"
    fi
fi

LLAMA_SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"
MODEL_PATH=""
MODEL_DIR="${HOME}/llm_models"

# Default parameters
BIND_HOST="127.0.0.1"
PORT=10000
CTX_SIZE=4096
LAYERS=60
BATCH_SIZE=256
MAIN_GPU=0
NUMA="distribute"
MMAP="no-mmap"
MLock="mlock"
THREADS=$(nproc)

# Flag to detect if user explicitly set --n-gpu-layers
USER_LAYERS_SET=0

# Function to display usage information
usage() {
    echo -e "${YELLOW}Usage: $0 [options]"
    echo -e "Options:"
    echo -e "  --model <model_path>      Path to the .gguf model to use"
    echo -e "  --port <port_number>      Port number on which to start the server (default: 10000)"
    echo -e "  --ctx-size <size>         Context size (default: 4096)"
    echo -e "  --n-gpu-layers <number>   Number of GPU layers (default: calculated dynamically)"
    echo -e "  --batch-size <size>       Batch size (default: 256)"
    echo -e "  --main-gpu <gpu_number>   Number of the main GPU (default: 0)"
    echo -e "  --numa <mode>             NUMA mode (default: distribute)"
    echo -e "  --mmap <option>           Use mmap to load the model (default: no-mmap)"
    echo -e "  --mlock                   Use mlock to lock memory (default: enabled)"
    echo -e "  --threads <number>        Number of threads (default: number of available cores)"
    echo -e "  --help                    Show this help screen"
    echo -e "${NC}"
    exit 0
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --model) MODEL_PATH="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --ctx-size) CTX_SIZE="$2"; shift 2 ;;
        --n-gpu-layers) LAYERS="$2"; USER_LAYERS_SET=1; shift 2 ;;
        --batch-size) BATCH_SIZE="$2"; shift 2 ;;
        --main-gpu) MAIN_GPU="$2"; shift 2 ;;
        --numa) NUMA="$2"; shift 2 ;;
        --mmap) MMAP="$2"; shift 2 ;;
        --mlock) MLock="mlock"; shift ;;
        --threads) THREADS="$2"; shift 2 ;;
        --help) usage ;;
        *) echo -e "${RED}❌ Error: Unrecognized option $1${NC}"; usage ;;
    esac
done

# Check if the binary exists and is executable
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
    echo -e "${RED}❌ Error: The llama-server binary does not exist or is not executable. Check the path and try again.${NC}"
    exit 1
fi

# Check if a model path is provided or search for .gguf files
if [ -z "$MODEL_PATH" ]; then
    echo -e "${YELLOW}⚠️  No model .gguf specified. Scanning for models in ${MODEL_DIR}/...${NC}"
    IFS=$'\n' read -d '' -r -a gguf_files < <(find "${MODEL_DIR}" -type f -name "*.gguf" -print 2>/dev/null | sort && printf '\0')
    if [ ${#gguf_files[@]} -eq 0 ]; then
        echo -e "${RED}❌ No .gguf files found in ${MODEL_DIR}/${NC}"
        exit 1
    fi
    echo -e "${GREEN}📦 Models found:${NC}"
    index=1
    for file in "${gguf_files[@]}"; do
        filename=$(basename "$file")
        if (( index % 2 == 1 )); then
            color=$YELLOW
        else
            color=$WHITE
        fi
        echo -e "[${GREEN}${index}${NC}] $color$filename${NC}"
        ((index++))
    done
    read -rp "👉 Enter the number of the desired model: " selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#gguf_files[@]}" ]; then
        echo -e "${RED}❌ Invalid selection. Exiting...${NC}"
        exit 1
    fi
    MODEL_PATH="${gguf_files[$((selection-1))]}"
fi

# Check if the model file exists and is readable
if [ ! -r "$MODEL_PATH" ]; then
    echo -e "${RED}❌ Error: The specified model file does not exist or is not readable. Check the path and try again.${NC}"
    exit 1
fi

# VRAM-based dynamic GPU layer assignment (only if user did NOT override)
if command -v nvidia-smi &> /dev/null; then
    if [ "$USER_LAYERS_SET" -eq 0 ]; then
        GPU_VRAM_FREE_MB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -n1)
        if [[ "$GPU_VRAM_FREE_MB" =~ ^[0-9]+$ ]]; then
            SAFETY_MARGIN_MB=1024
            USABLE_VRAM_MB=$((GPU_VRAM_FREE_MB - SAFETY_MARGIN_MB))
            (( USABLE_VRAM_MB < 0 )) && USABLE_VRAM_MB=0
            LAYER_SIZE_MB=370  
            LAYERS=$(( USABLE_VRAM_MB / LAYER_SIZE_MB ))
            (( LAYERS < 1 )) && LAYERS=1
            (( LAYERS > 1000 )) && LAYERS=1000
            echo -e "${YELLOW}🧠 Free VRAM: ${GPU_VRAM_FREE_MB} MB → Usable: ${USABLE_VRAM_MB} MB → Assigned layers: ${LAYERS}${NC}"
        else
            echo -e "${RED}⚠️  Error parsing free VRAM, using fallback: $LAYERS layers${NC}"
        fi
    else
        echo -e "${YELLOW}🔧 Using user-specified GPU layers: ${LAYERS}${NC}"
    fi
else
    echo -e "${RED}⚠️  nvidia-smi not available, using: ${LAYERS} layers${NC}"
fi

# Run the server with adaptive layer fallback and live output
echo -e "${GREEN}🚀 Starting llama-server with model: $MODEL_PATH${NC}"

while [ "$LAYERS" -ge 1 ]; do
    echo -e "${YELLOW}⚙️  Trying with GPU layers: $LAYERS${NC}"
    
    LOG_TMP=$(mktemp)
    
    "$LLAMA_SERVER_BIN" \
        --model "$MODEL_PATH" \
        --port "$PORT" \
        --host "$BIND_HOST" \
        --ctx-size "$CTX_SIZE" \
        --n-gpu-layers "$LAYERS" \
        --batch-size "$BATCH_SIZE" \
        --main-gpu "$MAIN_GPU" \
        --numa "$NUMA" \
        --"$MMAP" \
        --"$MLock" \
        --threads "$THREADS" \
        2>&1 | tee "$LOG_TMP" &
    
    PID=$!
    sleep 5

    if ! ps -p $PID > /dev/null; then
        if grep -q "cudaMalloc failed" "$LOG_TMP"; then
            echo -e "${RED}❌ cudaMalloc failed. Reducing GPU layers to $((LAYERS - 1)) and retrying...${NC}"
            LAYERS=$((LAYERS - 1))
            kill -9 $PID 2>/dev/null
            sleep 1
        else
            echo -e "${RED}❌ Model load failed (not due to cudaMalloc). See full output below:${NC}"
            cat "$LOG_TMP"
            break
        fi
    else
        echo -e "${GREEN}✅ llama-server started successfully with $LAYERS GPU layers.${NC}"
        echo -e "${WHITE}💡 Suggestion: next time use: --n-gpu-layers $LAYERS${NC}"
        wait $PID
        break
    fi
done

rm -f "$LOG_TMP"
