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
    if [ -f "/opt/ros/jazzy/setup.bash" ]; then echo "jazzy"; return; fi
    if [ -f "/opt/ros/humble/setup.bash" ]; then echo "humble"; return; fi
    
    echo "" # No ROS found
}

# 2. Detect Environment
ROS_DISTRO=$(find_ros_distro)
OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || true)}"

if [ -n "$ROS_DISTRO" ]; then
    echo "INFO: ROS 2 '$ROS_DISTRO' detected."
    PACKAGE_NAME="ros-${ROS_DISTRO}-insaion-agent"

    if [ "$ROS_DISTRO" = "humble" ]; then
        APT_REPO_NAME="insaion-jammy"
    else
        APT_REPO_NAME="insaion-noble"
    fi
else
    echo "INFO: No ROS 2 installation detected."
    echo "INFO: Defaulting to generic Native Ubuntu agent."
    PACKAGE_NAME="insaion-agent"

    case "$OS_CODENAME" in
        jammy)
            APT_REPO_NAME="insaion-jammy"
            ;;
        noble)
            APT_REPO_NAME="insaion-noble"
            ;;
        *)
            echo "FATAL: Unsupported Ubuntu codename '$OS_CODENAME' for generic package install."
            echo "Supported codenames: jammy, noble"
            exit 1
            ;;
    esac
fi

echo "INFO: Selected Gemfury APT repository: $APT_REPO_NAME"

# 3. Install prerequisites for adding repositories
echo "INFO: Installing network and repository prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gnupg apt-transport-https software-properties-common lsb-release

# 4. Add InfluxData Repository (For Telegraf dependency)
curl -fsSL https://repos.influxdata.com/influxdata-archive.key | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/influxdata-archive.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" > /etc/apt/sources.list.d/influxdata.list

# 4b. Pin Telegraf to 1.38.2 to avoid version conflicts
apt-get update -qq
apt-get install -y -qq "telegraf=1.38.2*"
apt-mark hold telegraf

# 5. Add Insaion Repository (Gemfury)
echo "INFO: Configuring Insaion repository..."
# Both Gemfury repositories use the same GPG key.
curl -fsSL https://apt.fury.io/insaion-jammy/gpg.key | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/insaion.gpg
echo "deb https://apt.fury.io/${APT_REPO_NAME}/ /" > /etc/apt/sources.list.d/insaion.list

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
apt-get install -y "$PACKAGE_NAME" --no-upgrade

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
echo "  - View live logs:     sudo journalctl -u insaion-agent -f"
echo "  - Check status:       sudo systemctl status insaion-agent"
echo "  - Restart agent:      sudo systemctl restart insaion-agent"
echo ""
