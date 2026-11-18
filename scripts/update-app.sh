#!/usr/bin/env bash
set -euo pipefail

# -- Configuration -------------------------------------------------------------
INSTALL_DIR="/opt/janus"
SERVICE_NAME="janus"
BIN_URL="https://github.com/rozsival/janus/releases/latest/download/janus"
BIN_PATH="${INSTALL_DIR}/bin/janus"
ENV_FILE="${INSTALL_DIR}/env"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/90-janus.conf"

# Installs from before the rename to Janus, migrated on the first update
LEGACY_NAME="panther-minor-controller"
LEGACY_DIR="/opt/${LEGACY_NAME}"
LEGACY_BIN_PATH="${LEGACY_DIR}/bin/${LEGACY_NAME}"
LEGACY_ENV_FILE="${LEGACY_DIR}/env"
LEGACY_UNIT="/etc/systemd/system/${LEGACY_NAME}.service"
LEGACY_JOURNALD_DROPIN="/etc/systemd/journald.conf.d/90-${LEGACY_NAME}.conf"

# -- Helpers -------------------------------------------------------------------
log_info() { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
log_success() { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
log_error() {
  printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""

  while ((count > 0)); do
    out+="$char"
    ((count--))
  done

  printf '%s' "$out"
}

print_summary_table() {
  local title="$1"
  shift

  if (($# % 2 != 0)); then
    printf 'print_summary_table requires label/value pairs\n' >&2
    return 1
  fi

  local -a labels=()
  local -a values=()
  local label_width=0
  local inner_width=${#title}
  local i
  local row_text
  local border

  while (($# > 0)); do
    labels+=("$1")
    values+=("$2")
    if ((${#1} > label_width)); then
      label_width=${#1}
    fi
    shift 2
  done

  for ((i = 0; i < ${#labels[@]}; i++)); do
    row_text=$(printf "%-*s : %s" "$label_width" "${labels[i]}" "${values[i]}")
    if ((${#row_text} > inner_width)); then
      inner_width=${#row_text}
    fi
  done

  border="+$(repeat_char "-" $((inner_width + 2)))+"

  printf '\n\033[0;32m%s\033[0m\n' "$border"
  printf '\033[0;32m| %-*s |\033[0m\n' "$inner_width" "$title"
  printf '\033[0;32m|%s|\033[0m\n' "$(repeat_char "-" $((inner_width + 2)))"

  for ((i = 0; i < ${#labels[@]}; i++)); do
    row_text=$(printf "%-*s : %s" "$label_width" "${labels[i]}" "${values[i]}")
    printf '\033[0;32m| %-*s |\033[0m\n' "$inner_width" "$row_text"
  done

  printf '\033[0;32m%s\033[0m\n\n' "$border"
}

# -- Pre-flight ----------------------------------------------------------------
[[ $EUID -eq 0 ]] || log_error "This script must be run as root (use sudo)."

# -- Step 0: Verify existing installation -------------------------------------
# A legacy unit or dir left behind means a migration is pending or was interrupted; rerunning finishes it
MIGRATE=false
if [[ -f "$LEGACY_UNIT" || -d "$LEGACY_DIR" ]]; then
  [[ -f "$LEGACY_UNIT" || -f "$SYSTEMD_UNIT" ]] ||
    log_error "No unit found at ${LEGACY_UNIT} or ${SYSTEMD_UNIT}. Reinstall by running: sudo ./install-app.sh"
  [[ -f "$LEGACY_ENV_FILE" || -f "$ENV_FILE" ]] ||
    log_error "No env file found at ${LEGACY_ENV_FILE} or ${ENV_FILE}. Reinstall by running: sudo ./install-app.sh"
  MIGRATE=true
  log_info "Found legacy install at ${LEGACY_DIR}; it will be migrated to ${INSTALL_DIR}."
elif [[ -f "$BIN_PATH" ]]; then
  log_info "Found existing binary at ${BIN_PATH}."
else
  log_error "Binary not found at ${BIN_PATH}. Install first by running: sudo ./install-app.sh"
fi

# -- Step 1: Download new binary ----------------------------------------------
log_info "Downloading latest janus binary..."

CREATED_INSTALL_DIR=false
[[ -d "$INSTALL_DIR" ]] || CREATED_INSTALL_DIR=true
mkdir -p "${INSTALL_DIR}/bin"
TMPBIN="${BIN_PATH}.tmp"
curl -fsSL "$BIN_URL" -o "$TMPBIN"
chmod +x "$TMPBIN"

log_success "Downloaded to ${TMPBIN}."

# -- Step 2: Confirm overwrite ------------------------------------------------
echo ""
if [[ "$MIGRATE" == true ]]; then
  log_warn "This will migrate the legacy install:"
  echo "  ${LEGACY_DIR} -> ${INSTALL_DIR} (env settings kept)"
  echo "  ${LEGACY_NAME}.service -> ${SERVICE_NAME}.service"
  echo "  ${LEGACY_DIR} will be deleted"
else
  log_warn "This will overwrite the existing binary:"
  echo "  ${BIN_PATH}"
fi
echo ""
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  log_info "Aborted. No changes made."
  rm -f "$TMPBIN"
  if [[ "$CREATED_INSTALL_DIR" == true ]]; then
    rm -rf "$INSTALL_DIR"
  fi
  exit 0
fi

# -- Step 3: Replace binary & restart -----------------------------------------
log_info "Stopping service..."
if [[ "$MIGRATE" == true ]]; then
  systemctl disable --now "$LEGACY_NAME" || true
else
  systemctl stop "$SERVICE_NAME" || true
fi

log_info "Replacing binary..."
mv "$TMPBIN" "$BIN_PATH"
chmod +x "$BIN_PATH"

log_success "Binary updated to ${BIN_PATH}."

if [[ "$MIGRATE" == true ]]; then
  log_info "Migrating legacy install..."

  # Each step is skipped once done, so an interrupted migration can be rerun
  if [[ -f "$LEGACY_ENV_FILE" ]]; then
    cp -p "$LEGACY_ENV_FILE" "$ENV_FILE"
    sed -i "s|^# Panther Minor Controller environment$|# Janus environment|" "$ENV_FILE"
  fi

  if [[ -f "$LEGACY_UNIT" ]]; then
    # Same user and options as the legacy unit, only the paths and name change
    sed \
      -e "s|^Description=.*|Description=Janus|" \
      -e "s|${LEGACY_BIN_PATH}|${BIN_PATH}|g" \
      -e "s|${LEGACY_ENV_FILE}|${ENV_FILE}|g" \
      "$LEGACY_UNIT" >"$SYSTEMD_UNIT"
    rm -f "$LEGACY_UNIT"
  fi

  if [[ -f "$LEGACY_JOURNALD_DROPIN" ]]; then
    sed "s|${LEGACY_NAME}|janus|g" "$LEGACY_JOURNALD_DROPIN" >"$JOURNALD_DROPIN"
    rm -f "$LEGACY_JOURNALD_DROPIN"
  fi

  rm -rf "$LEGACY_DIR"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"

  log_success "Migrated ${LEGACY_NAME} to ${SERVICE_NAME}."
fi

log_info "Starting service..."
systemctl start "$SERVICE_NAME"

# -- Summary -------------------------------------------------------------------
print_summary_table \
  "Janus updated!" \
  "Binary" "${BIN_PATH}" \
  "Service" "$SERVICE_NAME"

log_info "Useful commands:"
echo "  systemctl status ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME} -f"
