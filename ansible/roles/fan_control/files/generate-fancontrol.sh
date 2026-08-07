#!/usr/bin/env bash
# Deployed by Ansible role: fan_control
#
# PURPOSE
#   Resolve dynamic hardware sensor paths exposed by the nct6687 driver,
#   write a fresh /etc/fancontrol config with the predetermined fan curve,
#   then restart the fancontrol service so the new config takes effect.
#
# WHY THIS EXISTS
#   The nct6687 driver exposes sensor paths under /sys/class/hwmon/ using
#   IDs (hwmon0, hwmon1, ...) that are assigned at module load time and can
#   change between kernel versions or reboots. /etc/fancontrol embeds these
#   paths directly, so a static config breaks on every kernel upgrade.
#   This script regenerates the config each boot with the current IDs.
#
# USAGE
#   Called by the generate-fancontrol.service systemd unit at boot.
#   Can also be run manually: /usr/local/bin/generate-fancontrol.sh

set -euo pipefail

# Function to find hwmon directory by device name
find_hwmon_dir() {
    local label="$1"
    for d in /sys/class/hwmon/hwmon*; do
        if [[ "$(cat "$d/name")" == "$label" ]]; then
            echo "$d"
            return
        fi
    done
    echo ""
}

# Detect hwmon directories
DIR_NCT6687=$(find_hwmon_dir "nct6687")   # motherboard/PSU sensors
DIR_K10TEMP=$(find_hwmon_dir "k10temp")   # CPU
DIR_DRIVETEMP=$(find_hwmon_dir "drivetemp") # HDDs (optional)

# Validate detection of the devices that can never be missing
if [[ -z "$DIR_NCT6687" || -z "$DIR_K10TEMP" ]]; then
    echo "Error: Could not detect nct6687 or k10temp hwmon devices." >&2
    exit 1
fi

# Assign PWM/FAN/TEMP paths
PWM1="$DIR_NCT6687/pwm1"
PWM2="$DIR_NCT6687/pwm2"
PWM3="$DIR_NCT6687/pwm3"
PWM4="$DIR_NCT6687/pwm4"
PWM5="$DIR_NCT6687/pwm5"

FAN1="$DIR_NCT6687/fan1_input"
FAN2="$DIR_NCT6687/fan2_input"
FAN3="$DIR_NCT6687/fan3_input"
FAN4="$DIR_NCT6687/fan4_input"
FAN5="$DIR_NCT6687/fan5_input"

TEMP1_CPU="$DIR_K10TEMP/temp1_input"
TEMP2_MOBO="$DIR_NCT6687/temp2_input"

# drivetemp appears only when a SATA drive exposing it is present.
# Fall back to the motherboard temperature so the drive fans still have a
# valid source instead of aborting the whole boot unit.
if [[ -z "$DIR_DRIVETEMP" ]]; then
    TEMP_HDD="$TEMP2_MOBO"
    echo "Warning: drivetemp hwmon not found; drive fans tied to motherboard temperature." >&2
else
    TEMP_HDD="$DIR_DRIVETEMP/temp1_input"
fi

# Generate /etc/fancontrol
tee /etc/fancontrol >/dev/null <<EOF
INTERVAL=10

# Fan mapping
FCFANS=$PWM5=$FAN5 \
$PWM4=$FAN4 \
$PWM3=$FAN3 \
$PWM2=$FAN2 \
$PWM1=$FAN1

# Temperature sources
FCTEMPS=$PWM5=$TEMP2_MOBO \
$PWM3=$TEMP2_MOBO \
$PWM4=$TEMP_HDD \
$PWM2=$TEMP_HDD \
$PWM1=$TEMP1_CPU

# Min/Max temperatures
MINTEMP=$PWM5=35 $PWM4=30 $PWM3=35 $PWM2=30 $PWM1=40
MAXTEMP=$PWM5=55 $PWM4=45 $PWM3=55 $PWM2=45 $PWM1=75

# Start/stop behavior
MINSTART=$PWM5=150 $PWM4=150 $PWM3=150 $PWM2=150 $PWM1=150
MINSTOP=$PWM5=0 $PWM4=0 $PWM3=0 $PWM2=0 $PWM1=0
EOF

echo "/etc/fancontrol generated successfully with:"
echo "  nct6687 -> $DIR_NCT6687"
echo "  k10temp -> $DIR_K10TEMP"
echo "  drivetemp -> $DIR_DRIVETEMP"
