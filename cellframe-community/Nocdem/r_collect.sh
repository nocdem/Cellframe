#!/bin/bash

# Version information
SCRIPT_VERSION="1.0"

# Clear the terminal screen
clear
echo "---------------------------------------------------------------"

# Configuration file path
CONFIG_FILE="r_collect.cfg"

# Check if configuration file exists, if not create it with default values
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file not found. Creating default configuration file."
    cat > "$CONFIG_FILE" << EOF
# Collect Configuration
CELL_MASTER_WALLET=""
KEL_MASTER_WALLET=""
CELL_THRESHOLD=100
KEL_THRESHOLD=1000
AUTO_TRANSFER=false
AUTO_UPDATE=true
CELL_NODES=("cell1")
KEL_NODES=("kel1" "kel2")
CELLFRAME_PATH="/opt/cellframe-node/bin/cellframe-node-cli"
CONFIG_PATH="/opt/cellframe-node/etc/network"
EOF
fi

# Load configuration
source "$CONFIG_FILE"

# URL to check for script updates
SCRIPT_URL="https://raw.githubusercontent.com/nocdem/Cellframe/main/cellframe-community/Nocdem/r_collect.sh"

# Function to check and update the script if needed
check_update() {
  latest_version=$(curl -s "$SCRIPT_URL" | grep -m 1 -oP 'SCRIPT_VERSION="\K[0-9.]+')
  if [[ "$latest_version" > "$SCRIPT_VERSION" ]]; then
    if [ "$AUTO_UPDATE" = true ]; then
      echo "New version $latest_version found. Updating the script."
      curl -s "$SCRIPT_URL" -o "$0"
      echo "Update completed. Restarting the script."
      exec "$0"
    else
      echo "New version $latest_version available. Auto update is disabled."
    fi
  else
    echo "Script is up to date. Current version: $SCRIPT_VERSION"
  fi
}

# Check for updates
check_update
echo "---------------------------------------------------------------"

# Function to execute SSH commands with error handling
ssh_exec() {
  local node="$1"
  local command="$2"
  result=$(ssh "$node" "$command" 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "    Error: Unable to connect to $node or execute command."
    return 1
  else
    echo "$result"
  fi
}

# Function to transfer funds to the master wallet if the balance exceeds the threshold
transfer_funds() {
  local node="$1"
  local net="$2"
  local wallet_balance="$3"
  local threshold="$4"
  local master_wallet="$5"
  local token="$6"
  
  if (( $(echo "$wallet_balance > $threshold" | bc -l) )); then
    value=$(echo "$wallet_balance - 0.05" | bc -l)
    transfer_command="$CELLFRAME_PATH tx_create -net $net -chain main -value ${value}e+18 -token $token -to_addr $master_wallet -from_wallet $node -fee 0.05e+18"
    
    if [ "$AUTO_TRANSFER" = true ]; then
      if [ -z "$master_wallet" ]; then
        echo "  Threshold exceeded but master wallet address is empty. Skipping transfer."
      else
        ssh_exec "$node" "$transfer_command"
        if [[ $? -eq 0 ]]; then
          echo "  Transfer of $value $token from $node to $master_wallet successful."
        else
          echo "  Transfer of $value $token from $node to $master_wallet failed."
        fi
      fi
    else
      echo "  Threshold exceeded. Auto transfer is disabled."
    fi
  fi
}

# Function to get wallet balance and transfer funds if threshold is exceeded
get_and_transfer() {
  local node="$1"
  local net="$2"
  local token="$3"
  local master_wallet="$4"
  local threshold="$5"

  # Get fee_addr from the configuration file
  fee_addr=$(ssh_exec "$node" "grep 'fee_addr' $CONFIG_PATH/$net.cfg" | awk -F'=' '{print $2}')
  if [[ $? -ne 0 ]]; then return; fi

  # Get wallet information
  wallet_info=$(ssh_exec "$node" "$CELLFRAME_PATH wallet info -addr $fee_addr")
  if [[ $? -ne 0 ]]; then return; fi
  wallet_balance=$(echo "$wallet_info" | grep -A 3 'tokens:' | grep 'coins:' | awk '{print $2}')
  echo "Node: $node"
  echo "  Wallet Balance: $wallet_balance $token"
  
  # Transfer funds if threshold is exceeded
  transfer_funds "$node" "$net" "$wallet_balance" "$threshold" "$master_wallet" "$token"
  
  echo "---------------------------------------------------------------"
}

# Loop through cell nodes and get their wallet information and transfer funds if needed
for node in "${CELL_NODES[@]}"; do
  get_and_transfer "$node" "Backbone" "CELL" "$CELL_MASTER_WALLET" "$CELL_THRESHOLD"
done

# Loop through kel nodes and get their wallet information and transfer funds if needed
for node in "${KEL_NODES[@]}"; do
  get_and_transfer "$node" "KelVPN" "KEL" "$KEL_MASTER_WALLET" "$KEL_THRESHOLD"
done
