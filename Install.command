#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  PDF Study — Installer
#  Double-click to choose Version 1 or Version 2, remove any existing copy of
#  the app, build the selected version from source and install it.
#
#  Non-interactive use:
#    ./Install.command --version 1|2 [--yes] [--purge-data] [--no-launch]
#    ./Install.command --uninstall   [--yes] [--purge-data]
#  Compatible with the stock macOS bash (3.2).
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

APP_NAME="PDF Study"
BUNDLE_ID="app.pdfstudy.PDFStudy"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VERSIONS_DIR="$SCRIPT_DIR/versions"
INSTALL_DIR="$HOME/Applications"
DEST="$INSTALL_DIR/$APP_NAME.app"
LOG="$HOME/Library/Logs/PDF-Study-Installer.log"
STATE_DIR="$HOME/Library/Application Support/PDF Study Installer"
STATE_FILE="$STATE_DIR/installed-version"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── Options ──────────────────────────────────────────────────────────────────
OPT_VERSION=""; OPT_UNINSTALL=0; ASSUME_YES=0; PURGE=0; NO_LAUNCH=0
usage() {
  cat <<USAGE
PDF Study installer
  Install.command                      interactive menu
  Install.command --version 1|2        install a version without the menu
  Install.command --uninstall          remove PDF Study only
Options: --yes (no confirmation)  --purge-data (also delete library, annotations, backups)  --no-launch
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    [[ $# -ge 2 ]] || { usage; exit 2; }; OPT_VERSION="$2"; shift 2 ;;
    --uninstall)  OPT_UNINSTALL=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --purge-data) PURGE=1; shift ;;
    --no-launch)  NO_LAUNCH=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage; exit 2 ;;
  esac
done
if [[ -n "$OPT_VERSION" && "$OPT_VERSION" != "1" && "$OPT_VERSION" != "2" ]]; then
  echo "Version must be 1 or 2." >&2; exit 2
fi

# ── Look & feel ──────────────────────────────────────────────────────────────
ESC=$'\033'
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  IS_TTY=1
  C_RESET="${ESC}[0m"; C_BOLD="${ESC}[1m"; C_DIM="${ESC}[2m"
  C_BLUE="${ESC}[38;5;75m"; C_GREEN="${ESC}[38;5;78m"; C_RED="${ESC}[38;5;203m"
  C_YELLOW="${ESC}[38;5;221m"; C_GRAY="${ESC}[38;5;244m"; EL="${ESC}[K"
else
  IS_TTY=0
  C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_GRAY=""; EL=""
fi
OK="${C_GREEN}✔${C_RESET}"; BAD="${C_RED}✘${C_RESET}"; WARN="${C_YELLOW}▲${C_RESET}"
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

fg() { if (( IS_TTY )); then printf '%s[38;5;%sm' "$ESC" "$1"; fi; }
cursor_hide() { if (( IS_TTY )); then printf '%s[?25l' "$ESC"; fi; }
cursor_show() { if (( IS_TTY )); then printf '%s[?25h' "$ESC"; fi; }
tilde() { if [[ "$1" == "$HOME"/* ]]; then printf '~/%s' "${1#"$HOME"/}"; else printf '%s' "$1"; fi; }

G_P="████ |█   █|████ |█    |█    "
G_D="████ |█   █|█   █|█   █|████ "
G_F="█████|█    |████ |█    |█    "
G_S=" ████|█    | ███ |    █|████ "
G_T="█████|  █  |  █  |  █  |  █  "
G_U="█   █|█   █|█   █|█   █| ███ "
G_Y="█   █| █ █ |  █  |  █  |  █  "
banner() {
  local grads=(39 75 111 147 183) r l name line parts
  printf '\n'
  for r in 0 1 2 3 4; do
    line=""
    for l in P D F _ S T U Y; do
      if [[ "$l" == "_" ]]; then line="$line  "; continue; fi
      name="G_$l"
      IFS='|' read -ra parts <<< "${!name}"
      line="$line${parts[$r]} "
    done
    printf '   %s%s%s\n' "$(fg "${grads[$r]}")" "$line" "$C_RESET"
  done
  printf '\n   %sInstaller for macOS  ·  Apple Silicon  ·  Version 1 / Version 2%s\n' "$C_GRAY" "$C_RESET"
}
section() { printf '\n  %s╭─%s %s%s%s\n' "$C_GRAY" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"; }
row()     { printf '  %s│%s  %s\n' "$C_GRAY" "$C_RESET" "$1"; }
endsec()  { printf '  %s╰──────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_RESET"; }
has()     { command -v "$1" >/dev/null 2>&1; }

# ── Cleanup / failure handling ───────────────────────────────────────────────
WORK=""
cleanup() { cursor_show; if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf "$WORK"; fi; }
trap cleanup EXIT
trap 'cursor_show; printf "\n\n  Cancelled.\n"; exit 130' INT TERM

pause_close() {
  if (( IS_TTY && ! ASSUME_YES )); then
    printf '\n  %sPress Return to close this window…%s ' "$C_GRAY" "$C_RESET"
    read -r _ || true; printf '\n'
  fi
}
die() {
  section "Something went wrong"
  row "$BAD  $1"
  if [[ -n "${2:-}" ]]; then row ""; row "${C_GRAY}$2${C_RESET}"; fi
  endsec; pause_close; exit 1
}

# ── System check ─────────────────────────────────────────────────────────────
REQ_OK=1; HAVE_XCODEGEN=0; HAVE_BREW=0
check_system() {
  local ver major arch xcv xmaj
  section "System check"
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer only runs on macOS."
  ver="$(sw_vers -productVersion 2>/dev/null || echo 0)"; major="${ver%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 14 )); then row "$OK  macOS $ver"
  else row "$BAD  macOS $ver ${C_GRAY}(14 Sonoma or newer is required)${C_RESET}"; REQ_OK=0; fi

  arch="$(uname -m)"
  if [[ "$arch" == "arm64" ]]; then row "$OK  Apple Silicon (arm64)"
  else row "$BAD  $arch ${C_GRAY}(this app is built for Apple Silicon only)${C_RESET}"; REQ_OK=0; fi

  if has xcodebuild && xcodebuild -version >/dev/null 2>&1; then
    xcv="$(xcodebuild -version 2>/dev/null | head -n 1)"; xmaj="${xcv#Xcode }"; xmaj="${xmaj%%.*}"
    if [[ "$xmaj" =~ ^[0-9]+$ ]] && (( xmaj < 16 )); then row "$WARN  $xcv ${C_GRAY}(Xcode 16 or newer is recommended)${C_RESET}"
    else row "$OK  $xcv"; fi
  else
    row "$BAD  Xcode ${C_GRAY}(install from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app)${C_RESET}"; REQ_OK=0
  fi

  if has brew; then HAVE_BREW=1; fi
  if has xcodegen; then HAVE_XCODEGEN=1; row "$OK  XcodeGen $(xcodegen --version 2>/dev/null | head -n 1 | sed 's/^Version: //')"
  elif (( HAVE_BREW )); then row "$WARN  XcodeGen ${C_GRAY}(will be installed with Homebrew)${C_RESET}"
  else row "$BAD  XcodeGen ${C_GRAY}(install Homebrew from https://brew.sh, or run: brew install xcodegen)${C_RESET}"; REQ_OK=0; fi
  endsec
}

# ── Existing installation ────────────────────────────────────────────────────
EXISTING=""; INSTALLED_KEY=""
find_installed() {
  local d app bid
  for d in "$HOME/Applications" "/Applications"; do
    [[ -d "$d" ]] || continue
    for app in "$d"/*.app; do
      [[ -d "$app" ]] || continue
      bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
      if [[ "$bid" == "$BUNDLE_ID" ]]; then printf '%s\n' "$app"; fi
    done
  done
}
data_paths() {
  printf '%s\n' "$HOME/Library/Application Support/PDF Study" \
    "$HOME/Library/Caches/$BUNDLE_ID" \
    "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
}
data_exists() { local p; while IFS= read -r p; do if [[ -e "$p" ]]; then return 0; fi; done <<< "$(data_paths)"; return 1; }

detect_existing() {
  local app v
  EXISTING="$(find_installed)"
  if [[ -f "$STATE_FILE" ]]; then INSTALLED_KEY="$(head -n 1 "$STATE_FILE" 2>/dev/null || true)"; fi
  if [[ -z "$EXISTING" ]]; then INSTALLED_KEY=""; fi
  section "Current installation"
  if [[ -z "$EXISTING" ]]; then row "${C_GRAY}PDF Study is not installed on this Mac.${C_RESET}"
  else
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo '?')"
      row "$OK  $(tilde "$app")  ${C_GRAY}(build $v${INSTALLED_KEY:+, installed as Version $INSTALLED_KEY})${C_RESET}"
    done <<< "$EXISTING"
  fi
  endsec
}

# ── Menu ─────────────────────────────────────────────────────────────────────
MENU_KEYS=(1 2 U Q)
MENU_TITLES=("Version 1" "Version 2" "Uninstall only" "Quit")
MENU_DESCS=("Original release: reader, annotations, library, vocabulary"
            "Adds Quick Tools: convert, combine, split, OCR, page editor"
            "Remove PDF Study from this Mac"
            "Exit without changing anything")
SEL=0; CHOICE=""
draw_menu() {
  local i tag
  for i in 0 1 2 3; do
    tag=""
    if [[ "${MENU_KEYS[$i]}" == "$INSTALLED_KEY" ]]; then tag="  ${C_GREEN}● installed${C_RESET}"; fi
    if (( i == SEL )); then
      printf '  %s❯ [%s]%s  %s%s%s%s%s\n' "$C_BLUE" "${MENU_KEYS[$i]}" "$C_RESET" "$C_BOLD" "${MENU_TITLES[$i]}" "$C_RESET" "$tag" "$EL"
      printf '         %s%s%s\n' "$C_RESET" "${MENU_DESCS[$i]}" "$EL"
    else
      printf '    %s[%s]%s  %s%s%s%s%s\n' "$C_GRAY" "${MENU_KEYS[$i]}" "$C_RESET" "$C_GRAY" "${MENU_TITLES[$i]}" "$C_RESET" "$tag" "$EL"
      printf '         %s%s%s%s\n' "$C_DIM" "${MENU_DESCS[$i]}" "$C_RESET" "$EL"
    fi
    printf '%s\n' "$EL"
  done
}
redraw_menu() { printf '%s[12A' "$ESC"; draw_menu; }
choose_menu() {
  local key rest
  section "What would you like to do?"
  printf '  %s│%s  %s↑ ↓ to move · Enter to select · or press 1 / 2 / U / Q%s\n  %s│%s\n' "$C_GRAY" "$C_RESET" "$C_GRAY" "$C_RESET" "$C_GRAY" "$C_RESET"
  cursor_hide; draw_menu
  while true; do
    if ! IFS= read -rsn1 key; then SEL=3; break; fi
    case "$key" in
      "$ESC") rest=""; read -rsn2 -t 1 rest || true
              case "$rest" in "[A") SEL=$(( (SEL + 3) % 4 )) ;; "[B") SEL=$(( (SEL + 1) % 4 )) ;; esac ;;
      k|K) SEL=$(( (SEL + 3) % 4 )) ;;
      j|J) SEL=$(( (SEL + 1) % 4 )) ;;
      1) SEL=0; break ;;
      2) SEL=1; break ;;
      u|U) SEL=2; break ;;
      q|Q) SEL=3; break ;;
      "") break ;;
    esac
    redraw_menu
  done
  redraw_menu; cursor_show
  CHOICE="${MENU_KEYS[$SEL]}"
}

ask() { # ask "question" Y|N  → returns 0 for yes
  local ans def="$2"
  if (( ASSUME_YES || ! IS_TTY )); then [[ "$def" == "Y" ]]; return; fi
  if [[ "$def" == "Y" ]]; then printf '\n  %s?%s %s %s[Y/n]%s ' "$C_BLUE" "$C_RESET" "$1" "$C_GRAY" "$C_RESET"
  else printf '\n  %s?%s %s %s[y/N]%s ' "$C_BLUE" "$C_RESET" "$1" "$C_GRAY" "$C_RESET"; fi
  read -r ans || ans=""
  case "$ans" in [yY]*) return 0 ;; [nN]*) return 1 ;; *) [[ "$def" == "Y" ]] ;; esac
}

# ── Step runner (spinner + log file) ─────────────────────────────────────────
run_step() { # run_step hard|soft "label" command [args…]
  local mode="$1" label="$2" start=$SECONDS rc=0 pid i=0 secs
  shift 2
  printf '\n### %s\n' "$label" >>"$LOG"
  ( "$@" ) >>"$LOG" 2>&1 &
  pid=$!
  if (( IS_TTY )); then
    cursor_hide
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s  %s  %s%ds%s%s' "$C_BLUE" "${SPIN[$((i % 10))]}" "$C_RESET" "$label" "$C_GRAY" $((SECONDS - start)) "$C_RESET" "$EL"
      i=$((i + 1)); sleep 0.1
    done
    cursor_show
  else
    printf '  … %s\n' "$label"
  fi
  wait "$pid" || rc=$?
  secs=$((SECONDS - start))
  if (( IS_TTY )); then printf '\r%s' "$EL"; fi
  if (( rc == 0 )); then printf '  %s  %s  %s%ds%s\n' "$OK" "$label" "$C_GRAY" "$secs" "$C_RESET"; return 0; fi
  if [[ "$mode" == "soft" ]]; then
    printf '  %s  %s  %s(finished with warnings — see log)%s\n' "$WARN" "$label" "$C_GRAY" "$C_RESET"; return 0
  fi
  printf '  %s  %s\n' "$BAD" "$label"
  section "What the build reported"
  { grep -E 'error:|\*\* BUILD FAILED|ERROR' "$LOG" | tail -n 14 || true; } | { grep . || tail -n 14 "$LOG"; } \
    | while IFS= read -r l; do row "${C_GRAY}${l:0:100}${C_RESET}"; done
  endsec
  die "The step “$label” failed." "Full log: $(tilde "$LOG")"
}

# ── Steps (each runs in a subshell; every command must fail loudly) ──────────
step_quit_app() {
  local n=0
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    osascript -e 'with timeout of 5 seconds' -e "tell application \"$APP_NAME\" to quit" -e 'end timeout' || true
    while pgrep -x "$APP_NAME" >/dev/null 2>&1 && (( n < 10 )); do sleep 0.5; n=$((n + 1)); done
    pkill -x "$APP_NAME" 2>/dev/null || true
  fi
  return 0
}
step_remove_old() {
  local app p
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    echo "removing $app"
    if [[ -w "$(dirname "$app")" ]]; then rm -rf "$app" || return 1; else sudo -n rm -rf "$app" || return 1; fi
  done <<< "$EXISTING"
  if (( PURGE )); then
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    while IFS= read -r p; do echo "deleting $p"; rm -rf "$p" || return 1; done <<< "$(data_paths)"
  fi
  rm -f "$STATE_FILE" || return 1
  return 0
}
step_install_xcodegen() { brew install xcodegen || return 1; }
step_prepare() {
  mkdir -p "$WORK/src" || return 1
  cp -R "$SRC/." "$WORK/src/" || return 1
  rm -rf "$WORK/src/build" "$WORK/src/dist" "$WORK/src/PDFStudy.xcodeproj" || return 1
  xattr -cr "$WORK/src" 2>/dev/null || true
  chmod +x "$WORK/src/scripts/"*.sh || return 1
}
step_verify() {
  local s rc=0
  cd "$WORK/src" || return 1
  has python3 || { echo "python3 not found — skipped"; return 0; }
  for s in scripts/verify_*.py scripts/static_check.py; do
    [[ -f "$s" ]] || continue
    echo "== $s"; python3 "$s" || rc=1
  done
  return $rc
}
step_build() { cd "$WORK/src" || return 1; scripts/build.sh release || return 1; }
step_check_bundle() {
  local app="$WORK/src/dist/$APP_NAME.app"
  [[ -x "$app/Contents/MacOS/$APP_NAME" ]] || { echo "executable missing in $app"; return 1; }
  codesign --verify --deep --strict "$app" 2>&1 || echo "codesign verification reported a problem (ad-hoc signature)"
  return 0
}
step_install() {
  mkdir -p "$INSTALL_DIR" "$STATE_DIR" || return 1
  rm -rf "$DEST" || return 1
  ditto "$WORK/src/dist/$APP_NAME.app" "$DEST" || return 1
  xattr -cr "$DEST" 2>/dev/null || true
  printf '%s\n' "$VER" > "$STATE_FILE" || return 1
}

# ── Main ─────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG")"; : > "$LOG"
if (( IS_TTY )) && [[ -z "$OPT_VERSION" && $OPT_UNINSTALL -eq 0 ]]; then printf '%s[2J%s[H' "$ESC" "$ESC"; fi
banner
check_system
detect_existing

if (( OPT_UNINSTALL )); then CHOICE="U"
elif [[ -n "$OPT_VERSION" ]]; then CHOICE="$OPT_VERSION"
elif (( IS_TTY )); then choose_menu
else usage; exit 2; fi

case "$CHOICE" in
  Q) printf '\n  %sNothing was changed. Bye!%s\n' "$C_GRAY" "$C_RESET"; exit 0 ;;
  U) MODE="uninstall" ;;
  1|2) MODE="install"; VER="$CHOICE" ;;
  *) die "Unknown choice: $CHOICE" ;;
esac

# Plan
HAVE_EXISTING=0; if [[ -n "$EXISTING" ]]; then HAVE_EXISTING=1; fi
if (( HAVE_EXISTING )) || data_exists; then
  if (( ! PURGE )) && ask "Also delete app data (library, annotations, backups)? Recommended: no." N; then PURGE=1; fi
fi
section "Plan"
if [[ "$MODE" == "install" ]]; then
  if (( REQ_OK == 0 )); then
    row "$BAD  Requirements are missing — see the system check above."; endsec
    die "Fix the items marked ✘, then run the installer again."
  fi
  SRC_YML="$(find "$VERSIONS_DIR/v$VER" -maxdepth 2 -name project.yml -print -quit 2>/dev/null || true)"
  [[ -n "$SRC_YML" ]] || { endsec; die "The files for Version $VER were not found in ${VERSIONS_DIR}/v$VER."; }
  SRC="$(dirname "$SRC_YML")"
  row "1.  Build Version $VER in a temporary folder ${C_GRAY}(your files stay untouched)${C_RESET}"
  if (( HAVE_EXISTING )); then row "2.  Remove the existing PDF Study, then install the new one"
  else row "2.  Install it to $(tilde "$INSTALL_DIR")"; fi
  row "3.  Launch PDF Study"
else
  if (( ! HAVE_EXISTING )) && ! (( PURGE )); then row "${C_GRAY}Nothing to remove.${C_RESET}"; endsec; pause_close; exit 0; fi
  row "1.  Quit and remove PDF Study from this Mac"
fi
if (( PURGE )); then row "${C_YELLOW}Your library, annotations and backups WILL be deleted.${C_RESET}"
else row "${C_GREEN}Your library, annotations and backups are kept.${C_RESET}"; fi
endsec
if ! ask "Continue?" Y; then printf '\n  %sNothing was changed.%s\n' "$C_GRAY" "$C_RESET"; pause_close; exit 0; fi

# Administrator rights are only needed if an old copy sits in a protected folder.
if (( HAVE_EXISTING )); then
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    if [[ ! -w "$(dirname "$app")" ]]; then
      printf '\n  %sAdministrator permission is needed to remove %s%s\n' "$C_YELLOW" "$(tilde "$app")" "$C_RESET"
      sudo -v || die "Administrator permission was not granted."
      break
    fi
  done <<< "$EXISTING"
fi

START_ALL=$SECONDS
printf '\n'
if [[ "$MODE" == "install" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/pdfstudy-install.XXXXXX")"
  if (( ! HAVE_XCODEGEN )); then run_step hard "Installing XcodeGen" step_install_xcodegen; fi
  run_step hard "Preparing Version $VER sources" step_prepare
  run_step soft "Running verification checks" step_verify
  run_step hard "Building Version $VER (Release) — a few minutes" step_build
  run_step hard "Verifying the app bundle" step_check_bundle
  run_step hard "Closing PDF Study" step_quit_app
  if (( HAVE_EXISTING || PURGE )); then run_step hard "Removing the existing installation" step_remove_old; fi
  run_step hard "Installing Version $VER to $(tilde "$INSTALL_DIR")" step_install
  total=$((SECONDS - START_ALL))
  section "All done"
  row "$OK  ${C_BOLD}PDF Study — Version $VER${C_RESET} is installed  ${C_GRAY}(${total}s)${C_RESET}"
  row ""
  row "${C_GRAY}Location${C_RESET}   $(tilde "$DEST")"
  if (( PURGE )); then row "${C_GRAY}Your data${C_RESET}  deleted"; else row "${C_GRAY}Your data${C_RESET}  kept"; fi
  row "${C_GRAY}Log${C_RESET}        $(tilde "$LOG")"
  row ""
  row "${C_GRAY}If macOS blocks the first launch: right-click the app → Open.${C_RESET}"
  endsec
  if (( ! NO_LAUNCH )); then open "$DEST" || true; fi
else
  run_step hard "Closing PDF Study" step_quit_app
  run_step hard "Removing PDF Study" step_remove_old
  section "All done"
  row "$OK  ${C_BOLD}PDF Study${C_RESET} was removed from this Mac"
  if (( PURGE )); then row "${C_GRAY}Your data${C_RESET}  deleted"; else row "${C_GRAY}Your data${C_RESET}  kept"; fi
  endsec
fi
pause_close
