#!/bin/bash
# install.sh: installs metacheck on your own computer (macOS and Linux).
#
# Start it in a terminal with:
#   curl -fsSL https://raw.githubusercontent.com/scienceverse/metacheck_platform_docker/main/install.sh | bash
#
# It asks what to install, each time with "no" as the answer when you only
# press Enter, so the default is the lightest installation: PDFs are converted
# by TU/e's GROBID server, and the power check uses no language model, or
# Mistral with your own API key. The answers can also be given in advance, as
# settings before "bash":
#   curl -fsSL <address of this file> | GROBID=yes OLLAMA=no MISTRAL_KEY=skip bash
# (also INSTALL_DOCKER, REPLACE_SETTINGS, FOLDER, IMAGE and NO_START=1). It
# writes compose.yaml, the settings (.env) and start and stop files to a folder
# (default: metacheck in your home folder), and starts metacheck.
# Written for the bash of macOS (3.2) as well.

set -u

FOLDER="${FOLDER:-$HOME/metacheck}"
SOURCE="${SOURCE:-https://raw.githubusercontent.com/scienceverse/metacheck_platform_docker/main}"
MODEL="qwen3.5:4b"
MISTRAL_KEYS_PAGE="https://console.mistral.ai/api-keys"
OS="${METACHECK_OS:-$(uname -s)}"

say() { printf '%s\n' "$*"; }
heading() { printf '\n\033[36m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }

# The answers come from the keyboard, also when this script arrives through a
# pipe (curl ... | bash), which takes the place of the keyboard otherwise.
ask_line() {  # ask_line "question" -> the answer in $REPLY
  if [ -r /dev/tty ]; then read -r -p "$1 " REPLY < /dev/tty; else REPLY=""; fi
}
# A yes/no question; Enter means no. $2: the answer given in advance.
ask() {
  if [ -n "${2:-}" ]; then say "$1 $2"; [ "$2" = "yes" ]; return; fi
  ask_line "$1 [y/N]"
  case "$REPLY" in y|Y|yes|Yes|YES|j|J|ja|Ja) return 0 ;; *) return 1 ;; esac
}

case "$OS" in
  Darwin) SYSTEM=mac ;;
  Linux) SYSTEM=linux ;;
  *) say "This installer is for macOS and Linux. On Windows, use install.ps1 (see the README)."; exit 1 ;;
esac

# docker, or "sudo docker" on Linux when this user is not in the docker group.
DOCKER="docker"
docker_runs() {
  have docker || return 1
  if docker info > /dev/null 2>&1; then DOCKER="docker"; return 0; fi
  if [ "$SYSTEM" = linux ] && sudo -n true 2> /dev/null && sudo docker info > /dev/null 2>&1; then
    DOCKER="sudo docker"; return 0
  fi
  return 1
}

say ""
printf '\033[36m%s\033[0m\n' "metacheck on your own computer"
say "This installs metacheck's website and paper report app on this computer, in Docker."
say "The lightest installation needs little memory, but sends some things to external servers:"
say "  - a PDF is sent to the GROBID server of Eindhoven University of Technology (TU/e) to be converted;"
say "  - the power check uses no language model, or Mistral (EU) with your own API key."
say "Each part you add below does more on this computer instead. Press Enter for 'no'."

if [ "$SYSTEM" = mac ]; then
  MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
else
  MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1048576 ))
fi

# ---- Docker -----------------------------------------------------------------
heading "1. Docker"
if have docker; then
  say "Docker is installed."
else
  say "metacheck runs in Docker, which is not installed."
  if [ "$SYSTEM" = mac ]; then
    say "Docker Desktop is free for personal use, education, non-commercial open source and small"
    say "businesses; larger companies need a subscription."
    if ! ask "Install Docker Desktop now (with Homebrew)?" "${INSTALL_DOCKER:-}"; then
      say "metacheck cannot run without Docker. Install Docker Desktop from"
      say "https://www.docker.com/products/docker-desktop/ and run this installer again."
      exit 0
    fi
    if ! have brew; then
      say "Homebrew is not installed. Install Docker Desktop from"
      say "https://www.docker.com/products/docker-desktop/ and run this installer again."
      exit 1
    fi
    brew install --cask docker-desktop || exit 1
  else
    if ! ask "Install Docker Engine now (with Docker's script, get.docker.com; asks for your password)?" "${INSTALL_DOCKER:-}"; then
      say "metacheck cannot run without Docker. See https://docs.docker.com/engine/install/ and run"
      say "this installer again."
      exit 0
    fi
    curl -fsSL https://get.docker.com | sudo sh || exit 1
    sudo systemctl enable --now docker > /dev/null 2>&1
  fi
fi
if ! docker_runs; then
  if [ "$SYSTEM" = mac ]; then
    say "Start Docker Desktop (in Applications) and accept its terms. Waiting for Docker to answer..."
    open -a Docker 2> /dev/null
  else
    say "Waiting for Docker to answer (your password may be asked)..."
    sudo -v
  fi
  waited=0
  while ! docker_runs && [ "$waited" -lt 600 ]; do sleep 5; waited=$((waited + 5)); done
  if ! docker_runs; then
    say "Docker does not answer after 10 minutes. Start Docker, and run this installer again."
    exit 1
  fi
fi
say "Docker runs."

# ---- GROBID -----------------------------------------------------------------
heading "2. GROBID on this computer (converts PDFs)"
say "Without it, a PDF is sent to TU/e's GROBID server (GDPR compliant) to be converted."
say "With it, PDFs stay on this computer, but GROBID needs about 4 GB of memory more"
say "(a computer with 16 GB of memory; this one has $MEM_GB GB)."
USE_GROBID=no
if ask "Install GROBID on this computer?" "${GROBID:-}"; then
  USE_GROBID=yes
  if [ "$MEM_GB" -lt 16 ]; then
    warn "Note: with $MEM_GB GB of memory, GROBID may be stopped while converting a long PDF."
  fi
  if [ "$SYSTEM" = mac ]; then
    say "Docker Desktop must give Docker at least 6 GB of memory: see Docker Desktop's Settings > Resources."
  fi
fi

# ---- Language model -----------------------------------------------------------
heading "3. Language model for the power check"
say "The power check can use a language model to check whether power analyses report all"
say "the required information. Ollama runs a model on this computer, so the paragraphs stay"
say "here; it needs about 3.5 GB of disk space and memory (on the graphics card, if there is one)."
USE_OLLAMA=no
MISTRAL=""
OLLAMA_URL="http://host.docker.internal:11434"
if ask "Install Ollama with the model $MODEL?" "${OLLAMA:-}"; then
  USE_OLLAMA=yes
  if [ "$SYSTEM" = mac ]; then
    if [ ! -d /Applications/Ollama.app ]; then
      if ! have brew; then say "Homebrew is not installed. Install Ollama from https://ollama.com and run this installer again."; exit 1; fi
      brew install --cask ollama-app || exit 1
    fi
    # A context of 16384 tokens, as on metacheck's SURF server, for the Ollama
    # app (until the computer restarts; see Ollama's FAQ to keep it).
    launchctl setenv OLLAMA_CONTEXT_LENGTH 16384
    osascript -e 'quit app "Ollama"' > /dev/null 2>&1; sleep 2
    open -a Ollama
  else
    have ollama || { curl -fsSL https://ollama.com/install.sh | sh || exit 1; }
    # Ollama has no login, so it listens on Docker's own network address only
    # (as on metacheck's SURF server), which metacheck's container reaches and
    # other computers do not; and a context of 16384 tokens. That address only
    # exists once Docker runs, so Ollama starts after Docker.
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    printf '[Unit]\nAfter=docker.service\n[Service]\nEnvironment="OLLAMA_HOST=172.17.0.1"\nEnvironment="OLLAMA_CONTEXT_LENGTH=16384"\n' |
      sudo tee /etc/systemd/system/ollama.service.d/metacheck.conf > /dev/null
    sudo systemctl daemon-reload && sudo systemctl restart ollama
    export OLLAMA_HOST=172.17.0.1
    OLLAMA_URL="http://172.17.0.1:11434"
  fi
  waited=0
  until curl -sf "${OLLAMA_URL/host.docker.internal/localhost}/api/version" > /dev/null || [ "$waited" -ge 60 ]; do
    sleep 2; waited=$((waited + 2))
  done
  say "Downloading the model $MODEL (about 3.3 GB)..."
  ollama pull "$MODEL"
else
  say ""
  say "Instead, the power check can use Mistral (EU) with your own API key: the paragraphs about"
  say "statistical power are then sent to Mistral. Mistral's free plan needs no credit card;"
  say "check Mistral's terms for whether it may use what you send to improve its models."
  say "Get a key at $MISTRAL_KEYS_PAGE (log in, choose 'API Keys', 'Create new key')."
  given="${MISTRAL_KEY:-}"
  while true; do
    if [ -n "$given" ]; then answer="$given"; given="skip"
    else ask_line "Paste your Mistral API key, or press Enter to skip:"; answer="$REPLY"; fi
    if [ -z "$answer" ] || [ "$answer" = "skip" ]; then
      say "No language model. To add a key later, see the end of this installer."
      break
    fi
    key=$(printf '%s' "$answer" | tr -d '[:space:]')
    status=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -H "Authorization: Bearer $key" https://api.mistral.ai/v1/models)
    if [ "$status" = "200" ]; then say "Mistral accepts the key."; MISTRAL="$key"; break
    elif [ "$status" = "401" ]; then warn "Mistral does not accept this key; try again, or press Enter to skip."
    else warn "Mistral could not be reached to check the key (HTTP $status); the key is saved unchecked."; MISTRAL="$key"; break
    fi
  done
fi

# ---- bibr ----------------------------------------------------------------------
if have nvidia-smi; then
  heading "4. bibr"
  say "This computer has an NVIDIA graphics card. bibr, which converts PDFs and Word files better"
  say "than GROBID, needs a large one; it is not yet part of this installer."
fi

# ---- Files ---------------------------------------------------------------------
heading "Installing in $FOLDER"
mkdir -p "$FOLDER" || exit 1
if ! curl -fsSL "$SOURCE/compose.yaml" -o "$FOLDER/compose.yaml"; then
  say "compose.yaml could not be downloaded from $SOURCE."; exit 1
fi
ENV_FILE="$FOLDER/.env"
WRITE=yes
if [ -f "$ENV_FILE" ]; then
  ask "$ENV_FILE already holds settings. Replace them with these answers?" "${REPLACE_SETTINGS:-}" || WRITE=no
fi
if [ "$WRITE" = yes ]; then
  {
    say "# Settings of metacheck on this computer (written by install.sh). Change a line, then"
    say "# stop and start metacheck again. All settings: https://github.com/scienceverse/metacheck_platform_docker/blob/main/example.env"
    say "METACHECK_SETTINGS_FILE=$ENV_FILE"
    [ -n "${IMAGE:-}" ] && say "METACHECK_IMAGE=$IMAGE"
    if [ "$USE_GROBID" = yes ]; then
      say ""; say "# GROBID on this computer"; say "COMPOSE_PROFILES=grobid"
      say "GROBID_LOCAL_URL=http://grobid:8070"; say "METACHECK_GROBID_URL=http://grobid:8070"
    fi
    if [ "$USE_OLLAMA" = yes ]; then
      say ""; say "# Ollama on this computer"; say "OLLAMA_BASE_URL=$OLLAMA_URL"; say "METACHECK_LLM_MODEL=$MODEL"
    elif [ -n "$MISTRAL" ]; then
      say ""; say "# Mistral (EU) with your own API key"; say "MISTRAL_API_KEY=$MISTRAL"
    else
      say ""; say "# Mistral (EU) with your own API key ($MISTRAL_KEYS_PAGE): remove the # and add the key"
      say "# MISTRAL_API_KEY="
    fi
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"   # it may hold your API key
fi

# Start and stop files: double-clickable .command files on macOS.
EXT=sh; [ "$SYSTEM" = mac ] && EXT=command
OPEN="xdg-open"; [ "$SYSTEM" = mac ] && OPEN="open"
cat > "$FOLDER/start-metacheck.$EXT" <<EOF
#!/bin/bash
# Starts metacheck and opens it in the browser (written by install.sh).
cd "\$(dirname "\$0")" || exit 1
# first stop every part, also one that the settings no longer choose (such as GROBID)
$DOCKER compose --profile "*" down > /dev/null 2>&1
$DOCKER compose up -d || { echo "Is Docker running?"; exit 1; }
echo "Waiting for metacheck..."
for _ in \$(seq 1 90); do curl -sf http://localhost:3838/api/health > /dev/null && break; sleep 2; done
$DOCKER compose logs metacheck | grep -E "PDFs:|Language model:|WARNING|try again"
[ -z "\${METACHECK_NO_BROWSER:-}" ] && command -v $OPEN > /dev/null && $OPEN http://localhost:3838
echo "metacheck runs at http://localhost:3838 - stop it with stop-metacheck.$EXT"
EOF
cat > "$FOLDER/stop-metacheck.$EXT" <<EOF
#!/bin/bash
# Stops metacheck, every part of it (written by install.sh). Reports that were not saved are gone.
cd "\$(dirname "\$0")" || exit 1
$DOCKER compose --profile "*" down
EOF
chmod +x "$FOLDER/start-metacheck.$EXT" "$FOLDER/stop-metacheck.$EXT"

# ---- Start ---------------------------------------------------------------------
heading "Downloading metacheck (the first time this takes a while)"
cd "$FOLDER" || exit 1
[ -z "${IMAGE:-}" ] && $DOCKER compose pull
if [ -n "${NO_START:-}" ]; then say "Not started (NO_START)."; else "$FOLDER/start-metacheck.$EXT"; fi

heading "Done"
say "Start metacheck: $FOLDER/start-metacheck.$EXT   Stop it: $FOLDER/stop-metacheck.$EXT"
say "Website: http://localhost:3838    Paper report app: http://localhost:3838/metacheck/"
if [ "$USE_OLLAMA" = no ] && [ -z "$MISTRAL" ]; then
  say ""
  say "To use Mistral later: get a key at $MISTRAL_KEYS_PAGE, open $ENV_FILE in a text"
  say "editor, change the line '# MISTRAL_API_KEY=' into 'MISTRAL_API_KEY=' followed by your key,"
  say "and stop and start metacheck again."
fi
