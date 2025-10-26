#!/usr/bin/env bash

# Installer for Insaion Agent (clean user output)
# - Installs newest release (latest)
# - Autodetects ROS distro or generic Ubuntu
# - Installs prerequisites quietly
# - Downloads and installs a matching release for your system

set -euo pipefail

REPO_OWNER="insaion"
REPO_NAME="assets"
GITHUB_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download"

usage() {
  cat <<EOF
Usage: install-agent.sh [--url BASE_URL] [--ros ROS_DISTRO]

Notes:
  - This installer always selects the newest release automatically ("latest").
  - It will auto-detect your system (ROS or Generic Ubuntu) and download
    the correct package.
  - The --ros flag forces a ROS-specific installation.

Examples:
  # Install the newest release (autodetect system)
  curl -fsSL https://raw.githubusercontent.com/insaion/assets/main/install-agent.sh | sudo bash -s --

  # Specify ROS distro manually and install the newest release
  curl -fsSL https://raw.githubusercontent.com/insaion/assets/main/install-agent.sh | sudo bash -s -- --ros humble
EOF
}

# --- Parse args ---
TAG="latest"
BASE_URL="${GITHUB_BASE}"
ROS_ARG=""

while [[ ${#-} -gt 0 ]]; do
  case "${1-}" in
    --ros|--ros-distro)
      ROS_ARG="${2-}"
      shift 2 || true
      ;;
    --url)
      BASE_URL="${2-}"
      shift 2 || true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      # no more options
      break
      ;;
  esac
done

# Helpers
run_cmd() {
  if [[ $(id -u) -eq 0 ]]; then
    bash -c "$*"
  else
    sudo bash -c "$*"
  fi
}

detect_ros_distro() {
  # Prefer ROS_DISTRO env if set
  if [[ -n "${ROS_DISTRO-}" ]]; then
    echo "$ROS_DISTRO"
    return
  fi

  # Check /opt/ros/* directories
  if compgen -G "/opt/ros/*" > /dev/null; then
    for p in /opt/ros/*; do
      if [[ -d "$p" ]]; then
        basename "$p"
        return
      fi
    done
  fi

  echo ""
}

# New function to detect Ubuntu version for non-ROS systems
detect_ubuntu_codename() {
  if [ -f "/etc/os-release" ]; then
    # Source the file to get variables like $ID and $VERSION_CODENAME
    . /etc/os-release
    if [ "$ID" = "ubuntu" ]; then
      echo "$VERSION_CODENAME"
    else
      echo "" # Not Ubuntu
    fi
  else
    echo "" # Not a modern systemd-based Linux
  fi
}

detect_arch() {
  local m
  m=$(dpkg --print-architecture 2>/dev/null || true)
  if [[ -n "$m" ]]; then
    echo "$m"
    return
  fi
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armhf" ;;
    *) echo "$(uname -m)" ;;
  esac
}

download_file() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
  else
    wget -q -O "$dest" "$url"
  fi
}

# Ensure at least one network downloader is present (curl or wget).
ensure_network_utils() {
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    return 0
  fi

  echo "Preparing required network tools..."
  export DEBIAN_FRONTEND=noninteractive
  # Try to install curl and wget; tolerate failure (user can install manually)
  if command -v apt-get >/dev/null 2>&1; then
    run_cmd "apt-get -qq update -y && apt-get -qq install -y --no-install-recommends curl wget ca-certificates || true"
  else
    echo "Couldn't install required network tools automatically. Please install curl or wget and rerun." >&2
    return 1
  fi
  unset DEBIAN_FRONTEND
  return 0
}

# Install system prerequisites and telegraf (if not present).
install_prereqs() {
  echo "Installing prerequisites..."
  # Use non-interactive front-end
  export DEBIAN_FRONTEND=noninteractive

  # Ensure apt caches are available and basic tools installed
  run_cmd "apt-get -qq update -y"
  run_cmd "apt-get -qq install -y --no-install-recommends curl wget ca-certificates gnupg lsb-release apt-transport-https jq gettext-base || true"

  # Install monitoring agent repository using a verified key fingerprint (optional)
  local keyring_dir=/etc/apt/keyrings
  local keyring_file=${keyring_dir}/influxdata-archive.gpg
  local src=/etc/apt/sources.list.d/influxdata.list
  run_cmd "mkdir -p $keyring_dir"
  local tmpk
  tmpk="$(mktemp)"
  # Download key locally (not using sudo) and verify fingerprint
  if download_file "https://repos.influxdata.com/influxdata-archive.key" "$tmpk" >/dev/null 2>&1; then
    if gpg --show-keys --with-fingerprint --with-colons "$tmpk" 2>&1 | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$'; then
      # Install keyring and apt source as root
      run_cmd "cat '$tmpk' | gpg --dearmor | tee '$keyring_file' > /dev/null"
      run_cmd "chmod 0644 '$keyring_file' || true"
      run_cmd "printf 'deb [signed-by=$keyring_file] https://repos.influxdata.com/debian stable main' > '$src'"
      # Update and install telegraf
      run_cmd "apt-get -qq update -y"
      run_cmd "apt-get -qq install -y telegraf || true"
    else
      echo "Skipping optional monitoring component setup (key verification failed)." >&2
    fi
  else
    echo "Skipping optional monitoring component setup." >&2
  fi
  rm -f "$tmpk" || true
  unset DEBIAN_FRONTEND
}

# Resolve tag: 'latest' -> real tag name via GitHub redirect
resolve_tag() {
  local tag="$1"
  if [[ "$tag" == "latest" ]]; then
    # Prefer using the GitHub Releases API to get tag_name (supports optional GITHUB_TOKEN)
    local api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    local auth_header=()
    if [[ -n "${GITHUB_TOKEN-}" ]]; then
      auth_header=( -H "Authorization: token ${GITHUB_TOKEN}" )
    fi
    if command -v curl >/dev/null 2>&1; then
      local json
      if json=$(curl -fsSL "${auth_header[@]}" "$api_url" 2>/dev/null || true); then
        # try to extract tag_name
        local tagname
        if command -v jq >/dev/null 2>&1; then
          tagname=$(printf '%s' "$json" | jq -r '.tag_name // empty' || true)
        else
          tagname=$(printf '%s' "$json" | grep -oE '"tag_name":\s*"[^"]+"' | sed -E 's/"tag_name":\s*"([^"]+)"/\1/' | head -n1 || true)
        fi
        if [[ -n "$tagname" ]]; then
          echo "$tagname"
          return
        fi
      fi
    fi
    # Fallback to redirect resolution (older method)
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o /dev/null -w "%{url_effective}" "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest" | awk -F/ '{print $NF}'
    else
      wget --server-response --max-redirect=0 "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest" 2>&1 | awk '/Location:/ {print $2}' | tr -d '\r' | awk -F/ '{print $NF}'
    fi
  else
    echo "$tag"
  fi
}

main() {
  echo "Starting Insaion Agent installation..."

  local ROS
  ROS=$(detect_ros_distro)
  local ARCH
  ARCH=$(detect_arch)
  local pattern=""
  local system_desc=""

  if [[ -n "${ROS_ARG-}" ]]; then
    ROS="$ROS_ARG"
    echo "Using --ros override: $ROS"
  fi

  echo "Detected system architecture: $ARCH"

  if [[ -n "$ROS" ]]; then
    # --- ROS Mode ---
    system_desc="ROS $ROS ($ARCH)"
    echo "Detected system: $system_desc"
    
    local esc_ros
    esc_ros=$(printf '%s' "$ROS" | sed 's/[][^$.*/]/\\&/g')
    local esc_arch
    esc_arch=$(printf '%s' "$ARCH" | sed 's/[][^$.*/]/\\&/g')
    # Expect filenames of the form: ros-<distro>-cpp-agent_<version>_<arch>.deb
    pattern="^ros-${esc_ros}-cpp-agent_[^_]+_${esc_arch}\\.deb$"

  else
    # --- Generic Ubuntu Mode ---
    echo "No ROS installation detected. Checking for generic Ubuntu support..."
    local CODENAME
    CODENAME=$(detect_ubuntu_codename)
    
    if [[ -z "$CODENAME" ]]; then
        echo "ERROR: No ROS installation detected and this system is not a recognized Ubuntu release." >&2
        echo "If this is a ROS system, try running with --ros <distro>" >&2
        exit 1
    fi

    # Use codename-based matching (e.g., jammy, noble)
    local UBUNTU_CODENAME_TAG=""
    case "$CODENAME" in
      "jammy")  # 22.04
        UBUNTU_CODENAME_TAG="jammy"
        ;;
      "noble")  # 24.04
        UBUNTU_CODENAME_TAG="noble"
        ;;
      *)
        echo "ERROR: Your Ubuntu version ($CODENAME) is not officially supported for the generic agent." >&2
        echo "Supported versions are: jammy (22.04), noble (24.04)."
        exit 1
        ;;
    esac
    
    system_desc="Generic Ubuntu $CODENAME ($ARCH)"
    echo "Detected system: $system_desc"

    local esc_codename
    esc_codename=$(printf '%s' "$UBUNTU_CODENAME_TAG" | sed 's/[][^$.*/]/\\&/g')
    local esc_arch
    esc_arch=$(printf '%s' "$ARCH" | sed 's/[][^$.*/]/\\&/g')
    # Match only by codename: insaion-agent_<version>_<codename>_<arch>.deb
    pattern="^insaion-agent_[^_]+_${esc_codename}_${esc_arch}\\.deb$"
  fi

  # Ensure network downloader tools are present before making HTTP requests
  ensure_network_utils || true

  TAG_RESOLVED=$(resolve_tag "$TAG" || echo "$TAG")
  # Prepare temporary dir and check that the expected Debian asset exists for this release.
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR"' EXIT
  DEB_FILE="$TMPDIR/agent.deb"

  ASSETS_JSON="$TMPDIR/assets.json"
  release_api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/tags/${TAG_RESOLVED}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$release_api_url" -o "$ASSETS_JSON" || true
  else
    wget -qO "$ASSETS_JSON" "$release_api_url" || true
  fi

  if [[ ! -s "$ASSETS_JSON" ]]; then
    echo "ERROR: Could not fetch release info from GitHub API." >&2
    echo "URL: $release_api_url" >&2
    exit 2
  fi

  asset_name=""
  if command -v jq >/dev/null 2>&1; then
    asset_name=$(jq -r --arg pat "$pattern" '.assets[].name | select(test($pat))' "$ASSETS_JSON" | head -n1 || true)
  else
    asset_name=$(grep -oE '"name":\s*"[^"]+"' "$ASSETS_JSON" | sed -E 's/"name":\s*"([^"]+)"/\1/' | grep -E "$pattern" | head -n1 || true)
  fi

  if [[ -z "$asset_name" ]]; then
    echo "ERROR: No compatible agent package found for your system ($system_desc) in release $TAG_RESOLVED." >&2
    exit 2
  fi

  echo "Found matching package: $asset_name"
  echo "Downloading agent..."
  DEB_URL="${BASE_URL}/${TAG_RESOLVED}/${asset_name}"
  if ! download_file "$DEB_URL" "$DEB_FILE" || [[ ! -s "$DEB_FILE" ]]; then
    echo "ERROR: Unable to download the agent for this system." >&2
    exit 2
  fi

  echo "Installing agent..."

  # Ensure prerequisites (curl, gpg, telegraf, etc.) are present before installing the .deb
  install_prereqs || true

  # Install .deb and fix dependencies if necessary
  if ! run_cmd "dpkg -i '$DEB_FILE'"; then
    echo "Resolving dependencies..."
    run_cmd "apt-get -qq install -f -y"
    # Try installing again
    run_cmd "dpkg -i '$DEB_FILE' || true"
  fi

  # Ensure runtime directory exists
  run_cmd "mkdir -p /var/lib/insaion-agent"
  echo "Insaion Agent installation completed."
}

main "$@"
