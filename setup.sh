#!/usr/bin/env bash
# ==============================================================================
# assistit.nvim — One-Click Linux Setup & Local Model Installer
# Installs prerequisites (Neovim >= 0.10, Ollama), lets you choose 1 of 10
# curated local coding models (or offline mode), pulls the model, installs
# assistit.nvim, and configures Neovim safely without overwriting init.lua.
# ==============================================================================
set -euo pipefail

REPO_URL="https://github.com/Arvex-GH/assistit.nvim.git"
NVIM_RELEASE_VER="v0.10.4"

MODEL_CHOICE=""
ASSUME_YES=0
SKIP_PULL=0
DRY_RUN=0
NVIM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
NVIM_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"

# Bold / color helpers (disabled automatically when stdout is not a terminal)
if [ -t 1 ]; then
  C_BOLD="\033[1m"
  C_GREEN="\033[1;32m"
  C_CYAN="\033[1;36m"
  C_YELLOW="\033[1;33m"
  C_RED="\033[1;31m"
  C_RESET="\033[0m"
else
  C_BOLD=""
  C_GREEN=""
  C_CYAN=""
  C_YELLOW=""
  C_RED=""
  C_RESET=""
fi

info()  { printf "${C_CYAN}[assistit]${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}[  OK  ]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[ WARN ]${C_RESET} %s\n" "$*"; }
err()   { printf "${C_RED}[ERROR ]${C_RESET} %s\n" "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: ./setup.sh [options]

Options:
  -m, --model <0-10|tag>   Choose model number (1-10), 0 for offline mode, or custom Ollama tag
  -y, --yes                Accept prompts non-interactively
      --skip-pull          Configure Neovim & plugin without installing/pulling via Ollama
      --config-dir <path>  Override Neovim config dir (default: ~/.config/nvim)
      --data-dir <path>    Override Neovim data dir (default: ~/.local/share/nvim)
      --dry-run            Print planned actions without modifying system packages
  -h, --help               Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model)
      MODEL_CHOICE="${2:-}"
      shift 2
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --skip-pull)
      SKIP_PULL=1
      shift
      ;;
    --config-dir)
      NVIM_CONFIG_DIR="${2:-}"
      shift 2
      ;;
    --data-dir)
      NVIM_DATA_DIR="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      SKIP_PULL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

prompt_input() {
  local prompt_text="$1"
  local default_val="$2"
  local reply=""
  if [ "$ASSUME_YES" -eq 1 ]; then
    printf "%s" "$default_val"
    return 0
  fi
  if [ -t 0 ]; then
    read -r -p "$prompt_text" reply || true
  elif [ -r /dev/tty ]; then
    read -r -p "$prompt_text" reply < /dev/tty || true
  fi
  if [ -z "$reply" ]; then
    printf "%s" "$default_val"
  else
    printf "%s" "$reply"
  fi
}

detect_ram_gb() {
  if [ -r /proc/meminfo ]; then
    awk '/MemTotal/ { printf "%d", int(($2 + 524288) / 1048576) }' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    if [ "$bytes" -gt 0 ] 2>/dev/null; then
      printf "%d" $(( bytes / 1073741824 ))
    else
      printf "8"
    fi
  else
    printf "8"
  fi
}

RAM_GB="$(detect_ram_gb)"
DEFAULT_CHOICE="1"
if [ "$RAM_GB" -ge 16 ] 2>/dev/null; then
  DEFAULT_CHOICE="7"
elif [ "$RAM_GB" -ge 8 ] 2>/dev/null; then
  DEFAULT_CHOICE="4"
fi

resolve_model_choice() {
  local choice="$1"
  case "$choice" in
    0|none|offline)
      SELECTED_PROVIDER="none"
      SELECTED_MODEL="deterministic-only"
      SELECTED_PROFILE="ultra_light"
      SELECTED_DESC="Offline deterministic + LSP intelligence (0 MB download)"
      ;;
    1)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="qwen2.5-coder:0.5b"
      SELECTED_PROFILE="ultra_light"
      SELECTED_DESC="Ultra-light CPU champion (~400 MB)"
      ;;
    2)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="deepseek-coder:1.3b"
      SELECTED_PROFILE="ultra_light"
      SELECTED_DESC="Fast multi-language FIM on CPU laptops (~780 MB)"
      ;;
    3)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="yi-coder:1.5b"
      SELECTED_PROFILE="balanced"
      SELECTED_DESC="Compact 128K-context all-rounder (~870 MB)"
      ;;
    4)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="qwen2.5-coder:1.5b"
      SELECTED_PROFILE="balanced"
      SELECTED_DESC="Everyday laptop sweet spot (~990 MB)"
      ;;
    5)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="codegemma:2b"
      SELECTED_PROFILE="balanced"
      SELECTED_DESC="Google fast FIM completion specialist (~1.6 GB)"
      ;;
    6)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="starcoder2:3b"
      SELECTED_PROFILE="balanced"
      SELECTED_DESC="BigCode 600+ languages FIM model (~1.7 GB)"
      ;;
    7)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="qwen2.5-coder:3b"
      SELECTED_PROFILE="balanced"
      SELECTED_DESC="Strong mid-size coder (~1.9 GB)"
      ;;
    8)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="deepseek-coder:6.7b"
      SELECTED_PROFILE="performance"
      SELECTED_DESC="Desktop / GPU high-accuracy coder (~3.8 GB)"
      ;;
    9)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="codellama:7b"
      SELECTED_PROFILE="performance"
      SELECTED_DESC="Meta CodeLlama 7B FIM classic (~3.8 GB)"
      ;;
    10)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="qwen2.5-coder:7b"
      SELECTED_PROFILE="performance"
      SELECTED_DESC="Workstation / GPU flagship coder (~4.7 GB)"
      ;;
    *)
      SELECTED_PROVIDER="ollama"
      SELECTED_MODEL="$choice"
      SELECTED_PROFILE="balanced"
      SELECTED_DESC="Custom Ollama model tag ($choice)"
      ;;
  esac
}

printf "\n${C_BOLD}======================================================================${C_RESET}\n"
printf "${C_BOLD}  assistit.nvim — One-Click Linux Setup (Detected RAM: ~%s GB)${C_RESET}\n" "$RAM_GB"
printf "${C_BOLD}======================================================================${C_RESET}\n\n"

if [ -z "$MODEL_CHOICE" ]; then
  cat <<EOF
Choose a local coding model to install via Ollama (100% local, zero cloud APIs):

  [1]  qwen2.5-coder:0.5b    (~400 MB | ~1 GB RAM)  Ultra-light CPU champion (4-8 GB laptops)
  [2]  deepseek-coder:1.3b   (~780 MB | ~2 GB RAM)  Fast multi-language FIM on CPU laptops
  [3]  yi-coder:1.5b         (~870 MB | ~2 GB RAM)  Compact 128K-context all-rounder
  [4]  qwen2.5-coder:1.5b    (~990 MB | ~2 GB RAM)  Everyday laptop sweet spot (8 GB+ RAM)
  [5]  codegemma:2b          (~1.6 GB | ~3 GB RAM)  Google fast FIM completion specialist
  [6]  starcoder2:3b         (~1.7 GB | ~4 GB RAM)  BigCode 600+ languages FIM model
  [7]  qwen2.5-coder:3b      (~1.9 GB | ~4 GB RAM)  Strong mid-size coder (8-16 GB RAM)
  [8]  deepseek-coder:6.7b   (~3.8 GB | ~6 GB RAM)  Desktop / GPU high-accuracy coder
  [9]  codellama:7b          (~3.8 GB | ~6 GB RAM)  Meta CodeLlama 7B FIM classic
  [10] qwen2.5-coder:7b      (~4.7 GB | ~8 GB RAM)  Workstation / GPU flagship coder
  ----------------------------------------------------------------------
  [0]  Offline Mode (none)   (   0 MB |   0 MB RAM)  Deterministic + LSP only (no AI download)

EOF
  MODEL_CHOICE="$(prompt_input "Enter choice [0-10 or custom Ollama tag] (default: ${DEFAULT_CHOICE}): " "$DEFAULT_CHOICE")"
fi

resolve_model_choice "$MODEL_CHOICE"
info "Selected: ${SELECTED_MODEL} (${SELECTED_DESC}) -> profile '${SELECTED_PROFILE}'"

install_pkg() {
  local pkg="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] Would install system package: $pkg"
    return 0
  fi
  local sudo_cmd=""
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    $sudo_cmd apt-get update -qq && $sudo_cmd apt-get install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    $sudo_cmd dnf install -y "$pkg"
  elif command -v pacman >/dev/null 2>&1; then
    $sudo_cmd pacman -Sy --noconfirm "$pkg"
  elif command -v zypper >/dev/null 2>&1; then
    $sudo_cmd zypper --non-interactive install "$pkg"
  elif command -v apk >/dev/null 2>&1; then
    $sudo_cmd apk add --no-cache "$pkg"
  else
    err "Please install '$pkg' manually using your distribution package manager."
    exit 1
  fi
}

# 1. Verify curl and git
for bin in curl git; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    warn "'$bin' not found. Installing '$bin'..."
    install_pkg "$bin"
  fi
done
ok "Found curl and git."

# 2. Verify Neovim >= 0.10.0
nvim_ok=0
if command -v nvim >/dev/null 2>&1; then
  nvim_ver="$(nvim --version | head -n1 | sed -E 's/^NVIM v([0-9]+)\.([0-9]+).*/\1 \2/')"
  nv_maj="$(printf "%s" "$nvim_ver" | awk '{print $1}')"
  nv_min="$(printf "%s" "$nvim_ver" | awk '{print $2}')"
  if [ "${nv_maj:-0}" -gt 0 ] 2>/dev/null || [ "${nv_min:-0}" -ge 10 ] 2>/dev/null; then
    nvim_ok=1
  fi
fi

if [ "$nvim_ok" -eq 1 ]; then
  ok "Found compatible Neovim ($(nvim --version | head -n1))."
elif [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] Would install Neovim ${NVIM_RELEASE_VER} into ~/.local/bin"
else
  warn "Neovim >= 0.10.0 not found. Installing official Neovim ${NVIM_RELEASE_VER} into ~/.local..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) nvim_tar="nvim-linux-x86_64.tar.gz"; nvim_dir="nvim-linux-x86_64" ;;
    aarch64|arm64) nvim_tar="nvim-linux-arm64.tar.gz"; nvim_dir="nvim-linux-arm64" ;;
    *) err "Unsupported architecture '$arch'. Please install Neovim >= 0.10.0 manually."; exit 1 ;;
  esac
  mkdir -p "$HOME/.local/bin" "$HOME/.local/opt"
  tmp_tar="$(mktemp)"
  if ! curl -fL "https://github.com/neovim/neovim/releases/download/${NVIM_RELEASE_VER}/${nvim_tar}" -o "$tmp_tar"; then
    # Fallback archive name used on earlier 0.10 point releases
    nvim_tar="nvim-linux64.tar.gz"
    nvim_dir="nvim-linux64"
    curl -fL "https://github.com/neovim/neovim/releases/download/${NVIM_RELEASE_VER}/${nvim_tar}" -o "$tmp_tar"
  fi
  rm -rf "$HOME/.local/opt/nvim"
  tar -xzf "$tmp_tar" -C "$HOME/.local/opt"
  rm -f "$tmp_tar"
  mv "$HOME/.local/opt/${nvim_dir}" "$HOME/.local/opt/nvim"
  ln -sf "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"
  export PATH="$HOME/.local/bin:$PATH"
  ok "Installed $(nvim --version | head -n1) to ~/.local/bin/nvim"
fi

# 3. Install Ollama & pull selected model (unless Offline Mode or --skip-pull)
if [ "$SELECTED_PROVIDER" = "ollama" ] && [ "$SKIP_PULL" -eq 0 ]; then
  if ! command -v ollama >/dev/null 2>&1; then
    ans="$(prompt_input "Ollama is not installed. Install Ollama now? [Y/n]: " "Y")"
    case "$ans" in
      [Nn]*)
        err "Aborted Ollama install. Re-run with '--model 0' for offline mode or install Ollama manually."
        exit 1
        ;;
    esac
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  ok "Ollama CLI ready ($(ollama --version 2>/dev/null || echo 'installed'))."

  if ! curl -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; then
    info "Starting local Ollama server on 127.0.0.1:11434..."
    nohup ollama serve >"${TMPDIR:-/tmp}/assistit-ollama.log" 2>&1 &
    waited=0
    while ! curl -fsS --max-time 2 "http://127.0.0.1:11434/api/tags" >/dev/null 2>&1; do
      sleep 1
      waited=$(( waited + 1 ))
      if [ "$waited" -ge 20 ]; then
        warn "Ollama server is taking longer than 20s to start. Trying 'ollama pull' directly..."
        break
      fi
    done
  fi
  ok "Ollama local endpoint (127.0.0.1:11434) is reachable."

  info "Pulling model '${SELECTED_MODEL}' (this only downloads once)..."
  ollama pull "$SELECTED_MODEL"
  ok "Model '${SELECTED_MODEL}' is installed locally."
elif [ "$SELECTED_PROVIDER" = "none" ]; then
  ok "Offline mode selected — skipping Ollama and model download."
else
  info "Skipping Ollama model pull (--skip-pull / --dry-run)."
fi

# 4. Install assistit.nvim into Neovim packpath (or lazy.nvim spec if detected)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
PACK_DIR="${NVIM_DATA_DIR}/site/pack/assistit/start/assistit.nvim"

if [ "$DRY_RUN" -eq 1 ]; then
  info "[dry-run] Would install plugin to ${PACK_DIR} and write config in ${NVIM_CONFIG_DIR}"
  exit 0
fi

mkdir -p "$(dirname "$PACK_DIR")"

if [ -f "${SCRIPT_DIR}/lua/assistit/init.lua" ] && [ -f "${SCRIPT_DIR}/plugin/assistit.lua" ]; then
  info "Installing assistit.nvim from local checkout (${SCRIPT_DIR})..."
  if [ "$(cd "$SCRIPT_DIR" && pwd)" != "$(mkdir -p "$PACK_DIR" && cd "$PACK_DIR" && pwd)" ]; then
    rm -rf "$PACK_DIR"
    mkdir -p "$PACK_DIR"
    cp -R "${SCRIPT_DIR}/lua" "${SCRIPT_DIR}/plugin" "${SCRIPT_DIR}/doc" "$PACK_DIR/"
    [ -f "${SCRIPT_DIR}/README.md" ] && cp "${SCRIPT_DIR}/README.md" "$PACK_DIR/"
    [ -f "${SCRIPT_DIR}/LICENSE" ] && cp "${SCRIPT_DIR}/LICENSE" "$PACK_DIR/"
  fi
else
  if [ -d "${PACK_DIR}/.git" ]; then
    info "Updating existing assistit.nvim checkout in ${PACK_DIR}..."
    git -C "$PACK_DIR" pull --ff-only
  else
    info "Cloning assistit.nvim into ${PACK_DIR}..."
    rm -rf "$PACK_DIR"
    git clone --depth 1 "$REPO_URL" "$PACK_DIR"
  fi
fi
ok "Installed plugin files at ${PACK_DIR}"

# 5. Write non-destructive Neovim configuration
USE_LAZY_SPEC=0
if [ -d "${NVIM_CONFIG_DIR}/lua/plugins" ] && [ -f "${NVIM_CONFIG_DIR}/init.lua" ]; then
  if grep -q "lazy" "${NVIM_CONFIG_DIR}/init.lua" 2>/dev/null; then
    USE_LAZY_SPEC=1
  fi
fi

if [ "$USE_LAZY_SPEC" -eq 1 ]; then
  CFG_FILE="${NVIM_CONFIG_DIR}/lua/plugins/assistit.lua"
  mkdir -p "$(dirname "$CFG_FILE")"
  cat > "$CFG_FILE" <<EOF
-- Generated by assistit.nvim setup.sh (safe to edit or re-run ./setup.sh anytime)
return {
  "Arvex-GH/assistit.nvim",
  event = { "InsertEnter", "CmdlineEnter" },
  opts = {
    profile = "${SELECTED_PROFILE}",
    provider = "${SELECTED_PROVIDER}",
    model = "${SELECTED_MODEL}",
  },
}
EOF
  # Clean up standalone startup file if switching to lazy.nvim
  rm -f "${NVIM_CONFIG_DIR}/after/plugin/assistit_setup.lua"
  ok "Wrote lazy.nvim plugin spec: ${CFG_FILE}"
else
  CFG_FILE="${NVIM_CONFIG_DIR}/after/plugin/assistit_setup.lua"
  mkdir -p "$(dirname "$CFG_FILE")"
  cat > "$CFG_FILE" <<EOF
-- Generated by assistit.nvim setup.sh (safe to edit or re-run ./setup.sh anytime)
local ok, assistit = pcall(require, "assistit")
if ok and not assistit._initialized then
  assistit.setup({
    profile = "${SELECTED_PROFILE}",
    provider = "${SELECTED_PROVIDER}",
    model = "${SELECTED_MODEL}",
  })
end
EOF
  ok "Wrote auto-loaded Neovim config: ${CFG_FILE} (existing init.lua/init.vim untouched)"
fi

# 6. Generate Vimdoc helptags
if command -v nvim >/dev/null 2>&1; then
  nvim --headless -u NONE "+helptags ${PACK_DIR}/doc" +qa >/dev/null 2>&1 || true
  ok "Generated :help assistit documentation tags."
fi

printf "\n${C_GREEN}======================================================================${C_RESET}\n"
printf "${C_GREEN}  assistit.nvim is installed and ready!${C_RESET}\n"
printf "${C_GREEN}======================================================================${C_RESET}\n"
cat <<EOF

Active Configuration:
  Model:     ${SELECTED_MODEL}
  Provider:  ${SELECTED_PROVIDER}
  Profile:   ${SELECTED_PROFILE}
  Config:    ${CFG_FILE}

Open Neovim ('nvim') and try the short commands (lowercase or :Ai*):
  :ais              Open live status, privacy, & latency dashboard
  :aip <u|b|p>      Switch profile (ultra_light / balanced / performance)
  :aim <1-10|tag>   Switch active local model on the fly
  :aif              Fix diagnostic / selection in a safe diff preview
  :aie              Explain error or code at cursor
  :aig <prompt>     Generate code from natural language
  :air / :aio       Refactor or optimize selected code
  :aid / :ait       Generate docstrings or unit tests
  :aic              Clean duplicate imports & trailing spaces
  :checkhealth assistit

EOF
