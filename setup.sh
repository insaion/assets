#!/usr/bin/env bash

# Exit on any error
set -e

echo "=========================================="
echo " Insaion Agent Installation Wizard"
echo "=========================================="

# 1. Require sudo
if [ "$(id -u)" != "0" ]; then
    echo "FATAL: This script must be run as root. Please run with sudo."
    exit 1
fi

# The repository. Overridable for staging installs.
APT_REPO_URL="${INSAION_APT_REPO_URL:-https://apt.insaion.com}"
KEYRING_PATH="/usr/share/keyrings/insaion-archive-keyring.gpg"
APT_SOURCES="/etc/apt/sources.list.d/insaion.sources"
LEGACY_APT_SOURCES="/etc/apt/sources.list.d/insaion.list"
LEGACY_INFLUX_SOURCES="/etc/apt/sources.list.d/influxdata.list"

# --- Helper function to find ROS ---
find_ros_distro() {
    # Respect ROS_DISTRO if it's already set in the environment
    if [ -n "${ROS_DISTRO:-}" ]; then
        if [ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]; then
            echo "$ROS_DISTRO"
            return
        fi
    fi
    # If not set, check common distros
    if [ -f "/opt/ros/rolling/setup.bash" ]; then echo "rolling"; return; fi
    if [ -f "/opt/ros/lyrical/setup.bash" ]; then echo "lyrical"; return; fi
    if [ -f "/opt/ros/kilted/setup.bash" ]; then echo "kilted"; return; fi
    if [ -f "/opt/ros/jazzy/setup.bash" ]; then echo "jazzy"; return; fi
    if [ -f "/opt/ros/humble/setup.bash" ]; then echo "humble"; return; fi

    echo "" # No ROS found
}

# 2. Detect Environment
ROS_DISTRO=$(find_ros_distro)
OS_CODENAME="${VERSION_CODENAME:-}"
if [ -z "$OS_CODENAME" ] && [ -r /etc/os-release ]; then
    OS_CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
fi
if [ -z "$OS_CODENAME" ]; then
    OS_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
fi

if [ -n "$ROS_DISTRO" ]; then
    echo "INFO: ROS 2 '$ROS_DISTRO' detected."
    PACKAGE_NAME="ros-${ROS_DISTRO}-insaion-agent"

    # The suite follows the Ubuntu release each ROS distro is built against,
    # which is where that package actually exists.
    case "$ROS_DISTRO" in
        humble)                  APT_SUITE="jammy" ;;
        jazzy | kilted)          APT_SUITE="noble" ;;
        lyrical | rolling)       APT_SUITE="resolute" ;;
        *)
            echo "FATAL: Unsupported ROS 2 distribution '$ROS_DISTRO'."
            echo "Supported: humble, jazzy, kilted, lyrical, rolling"
            exit 1
            ;;
    esac

    if [ -n "$OS_CODENAME" ] && [ "$OS_CODENAME" != "$APT_SUITE" ]; then
        echo "WARNING: ROS 2 '$ROS_DISTRO' packages are built for Ubuntu '$APT_SUITE',"
        echo "WARNING: but this host is '$OS_CODENAME'. Installing the '$APT_SUITE'"
        echo "WARNING: packages anyway; report a problem if the agent misbehaves."
    fi
else
    echo "INFO: No ROS 2 installation detected."
    echo "INFO: Defaulting to generic Native Ubuntu agent."
    PACKAGE_NAME="insaion-agent"

    case "$OS_CODENAME" in
        jammy | noble | resolute)
            APT_SUITE="$OS_CODENAME"
            ;;
        *)
            echo "FATAL: Unsupported Ubuntu codename '${OS_CODENAME:-unknown}' for generic package install."
            echo "Supported codenames: jammy, noble, resolute"
            exit 1
            ;;
    esac
fi

echo "INFO: Package: $PACKAGE_NAME"
echo "INFO: Repository: $APT_REPO_URL (suite $APT_SUITE)"

# 3. Install prerequisites for adding repositories
echo "INFO: Installing network and repository prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates lsb-release

# ---------------------------------------------------------
# 4. Migrate hosts installed by an older version of this script
#
# Telegraf used to be installed from InfluxData's repository and pinned to a
# tested range. That range could not survive the repository moving on -- apt
# will not downgrade an already-installed package to satisfy an upper bound, so
# once anything pulled a newer Telegraf the agent became uninstallable. Telegraf
# now ships inside the agent package, so the external repository, the pin and
# the hold are all gone.
# ---------------------------------------------------------
echo "INFO: Clearing legacy Telegraf pins..."
apt-mark unhold telegraf >/dev/null 2>&1 || true
rm -f /etc/apt/preferences.d/insaion-telegraf.pref

# Only remove the InfluxData entry if it is the one this script wrote; an
# administrator may be using that repository for their own purposes.
if [ -f "$LEGACY_INFLUX_SOURCES" ] && grep -q "repos.influxdata.com" "$LEGACY_INFLUX_SOURCES" 2>/dev/null; then
    if [ "$(wc -l < "$LEGACY_INFLUX_SOURCES")" -le 1 ]; then
        echo "INFO: Removing the InfluxData repository added by an earlier installer."
        echo "INFO: The agent no longer needs it. A telegraf package installed"
        echo "INFO: earlier is left alone; remove it with 'apt-get purge telegraf'"
        echo "INFO: if nothing else on this host uses it."
        rm -f "$LEGACY_INFLUX_SOURCES"
    fi
fi

# Retire the flat Gemfury repository, which could not express suites.
if [ -f "$LEGACY_APT_SOURCES" ] && grep -q "apt.fury.io/insaion-" "$LEGACY_APT_SOURCES" 2>/dev/null; then
    echo "INFO: Retiring the legacy Gemfury repository entry."
    mv "$LEGACY_APT_SOURCES" "${LEGACY_APT_SOURCES}.replaced-by-setup-sh"
fi
# The old key was dropped into trusted.gpg.d, where apt trusts it for every
# repository on the machine. The new entry names its keyring explicitly.
rm -f /etc/apt/trusted.gpg.d/insaion.gpg

# ---------------------------------------------------------
# 5. Add the Insaion repository
# ---------------------------------------------------------
echo "INFO: Configuring the Insaion repository..."
install -d -m 0755 /usr/share/keyrings
TMP_KEY="$(mktemp)"
curl -fsSL "${APT_REPO_URL}/insaion-archive-keyring.gpg" -o "$TMP_KEY"
if ! gpg --show-keys "$TMP_KEY" >/dev/null 2>&1; then
    echo "FATAL: ${APT_REPO_URL}/insaion-archive-keyring.gpg is not a valid GPG keyring."
    rm -f "$TMP_KEY"
    exit 1
fi
install -m 0644 "$TMP_KEY" "$KEYRING_PATH"
rm -f "$TMP_KEY"

cat > "$APT_SOURCES" <<SOURCES
# Insaion agent packages. Managed by the Insaion installer.
Types: deb
URIs: ${APT_REPO_URL}
Suites: ${APT_SUITE}
Components: main
Signed-By: ${KEYRING_PATH}
SOURCES
chmod 0644 "$APT_SOURCES"

# ---------------------------------------------------------
# 6. Pre-configure Agent Environment Overrides
# ---------------------------------------------------------
echo "INFO: Applying environment configurations..."
mkdir -p /etc/default
CONFIG_FILE="/etc/default/insaion-agent"

# Create a clean file if one doesn't exist yet
if [ ! -f "$CONFIG_FILE" ]; then
    echo "# Insaion Agent Environment Configuration" > "$CONFIG_FILE"
    chmod 0644 "$CONFIG_FILE"
fi

# Helper function to safely write/update variables in the config file
set_config_var() {
    local var_name=$1
    local var_value=$2
    if [ -n "$var_value" ]; then
        # Escape backslashes, ampersands, and pipes for sed
        local escaped_value=$(printf '%s' "$var_value" | sed 's/[\\&|]/\\\\&/g')
        if grep -q "^${var_name}=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i "s|^${var_name}=.*|${var_name}=${escaped_value}|" "$CONFIG_FILE"
        else
            echo "${var_name}=${var_value}" >> "$CONFIG_FILE"
        fi
        echo "  -> Set ${var_name}"
    fi
}

# Write detected ROS distro so systemd can source it
set_config_var "ROS_DISTRO" "$ROS_DISTRO"

# Catch UI-provided variables from the CLI environment
set_config_var "ENROLLMENT_KEY" "$ENROLLMENT_KEY"
set_config_var "CUSTOM_ROS_SETUP" "$CUSTOM_ROS_SETUP"

# Global 
set_config_var "RMW_IMPLEMENTATION" "$RMW_IMPLEMENTATION"
set_config_var "ROS_DOMAIN_ID" "$ROS_DOMAIN_ID"
set_config_var "ROS_AUTOMATIC_DISCOVERY_RANGE" "$ROS_AUTOMATIC_DISCOVERY_RANGE"
set_config_var "ROS_STATIC_PEERS" "$ROS_STATIC_PEERS"

# Legacy Fallback (Humble)
set_config_var "ROS_LOCALHOST_ONLY" "$ROS_LOCALHOST_ONLY"

# FastDDS
set_config_var "FASTRTPS_DEFAULT_PROFILES_FILE" "$FASTRTPS_DEFAULT_PROFILES_FILE"
set_config_var "ROS_DISCOVERY_SERVER" "$ROS_DISCOVERY_SERVER"

# CycloneDDS
set_config_var "CYCLONEDDS_URI" "$CYCLONEDDS_URI"

# Zenoh
set_config_var "ZENOH_ROUTER_CONFIG_URI" "$ZENOH_ROUTER_CONFIG_URI"
set_config_var "ZENOH_SESSION_CONFIG_URI" "$ZENOH_SESSION_CONFIG_URI"
set_config_var "ZENOH_ROUTER_CHECK_ATTEMPTS" "$ZENOH_ROUTER_CHECK_ATTEMPTS"

# Export them so apt-get and postinst can inherit them gracefully
export ENROLLMENT_KEY CUSTOM_ROS_SETUP RMW_IMPLEMENTATION FASTRTPS_DEFAULT_PROFILES_FILE ROS_DOMAIN_ID ROS_DISTRO ROS_LOCALHOST_ONLY ROS_DISCOVERY_SERVER CYCLONEDDS_URI ZENOH_ROUTER_CONFIG_URI ZENOH_SESSION_CONFIG_URI ZENOH_ROUTER_CHECK_ATTEMPTS
# ---------------------------------------------------------

# 7. Install the Agent
echo "INFO: Updating package lists..."
apt-get update -qq
echo "INFO: Installing package: $PACKAGE_NAME"
# Re-running this script upgrades an existing install: that is how a host moves
# to a newer agent, and how the pre-vendoring layout is migrated. Set
# INSAION_NO_UPGRADE=1 to keep an already-installed version untouched.
if [ "${INSAION_NO_UPGRADE:-0}" = "1" ]; then
    apt-get install -y "$PACKAGE_NAME" --no-upgrade
else
    apt-get install -y "$PACKAGE_NAME"
fi

# 8. Post-Installation Output
echo ""
echo "=========================================="
echo " Installation Complete!"
echo "=========================================="
echo ""
echo "The Insaion Agent has been installed and is running in the background."
echo ""
echo "To pair this device, open your browser and navigate to:"
echo "http://$(hostname -I | awk '{print $1}'):9090"
echo ""
echo "Useful Commands:"
echo "  - View live logs:           sudo journalctl -u insaion-agent -f"
echo "  - Check status:             sudo systemctl status insaion-agent"
echo "  - Restart agent:            sudo systemctl restart insaion-agent"
echo "  - Bundle logs for support:  sudo insaion-agent --support-bundle"
echo ""
