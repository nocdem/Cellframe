#!/bin/bash

# Version information
SCRIPT_VERSION="1.55"

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
NODES=("cell1" "kel1" "kel2" "kel3")
CELLFRAME_PATH="/opt/cellframe-node/bin/cellframe-node-cli"
CONFIG_PATH="/opt/cellframe-node/etc/network"
SLEEPTIME=300
VERBOSE=false
EOF
fi

# Load configuration
source "$CONFIG_FILE"

# Function to print messages based on verbosity
print_message() {
  if [ "$VERBOSE" = true ]; then
    echo "$1"
  fi
}

# URL to check for script updates
SCRIPT_URL="https://raw.githubusercontent.com/nocdem/Cellframe/main/cellframe-community/Nocdem/r_collect.sh"

# Function to check and update the script if needed
check_update() {
  latest_version=$(curl -s "$SCRIPT_URL" | grep -m 1 -oP 'SCRIPT_VERSION="\K[0-9.]+')
  if [[ "$latest_version" > "$SCRIPT_VERSION" ]]; then
    if [ "$AUTO_UPDATE" = true ]; then
      echo "New version $latest_version found. Updating the script."
      if curl -s "$SCRIPT_URL" -o "$0"; then
        echo "Update completed. Restarting the script."
        exec "$0"
      else
        echo "Failed to download the update. Please check your network connection."
      fi
    else
      echo "New version $latest_version available. Auto update is disabled."
    fi
  else
    print_message "Script is up to date. Current version: $SCRIPT_VERSION"
  fi
}

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

# Function to check if the node is online
is_node_online() {
    local node=$1
    output=$(ssh_exec "$node" "$CELLFRAME_PATH version")
    if [[ $? -ne 0 ]]; then
        echo "Node $node is not online. SSH command failed."
        echo "---------------------------------------------------------------"
        return 1
    fi
    if [[ $output == *"Error 111: Failed socket connection"* ]]; then
        echo "Node $node is rebooting. Skipping..."
        echo "---------------------------------------------------------------"
        return 1
    fi
    return 0
}

# Function to get the token ticker based on the network
get_token_ticker() {
    local network=$1
    if [ "$network" == "KelVPN" ]; then
        echo "KEL"
    elif [ "$network" == "Backbone" ]; then
        echo "CELL"
    else
        echo ""
    fi
}

# Function to ensure numeric values are in a proper format
format_number() {
  local number=$1
  # Remove any commas or spaces and replace commas with dots
  formatted=$(echo "$number" | sed 's/[ ,]//g' | sed 's/,/./g')
  echo "$formatted"
}

# Function to transfer funds to the master wallet if the balance exceeds the threshold
transfer_funds() {
  local node="$1"
  local net="$2"
  local wallet_balance="$3"
  local threshold="$4"
  local master_wallet="$5"
  local token="$6"
  
  # Format wallet_balance and threshold
  wallet_balance=$(format_number "$wallet_balance")
  threshold=$(format_number "$threshold")

  # Ensure wallet_balance and threshold are numeric values
  if [[ ! "$wallet_balance" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ ! "$threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "  Invalid wallet balance or threshold value. Skipping transfer. (Node: $node)"
    return
  fi

  if (( $(echo "$wallet_balance > $threshold" | bc -l) )); then
    value=$(echo "$wallet_balance - 0.05" | bc -l)
    transfer_command="$CELLFRAME_PATH tx_create -net $net -chain main -value ${value}e+18 -token $token -to_addr $master_wallet -from_wallet $node -fee 0.05e+18"
    
    if [ "$AUTO_TRANSFER" = true ]; then
      if [ -z "$master_wallet" ]; then
        echo "  Threshold exceeded but master wallet address is empty. Skipping transfer."
      else
        transfer_output=$(ssh_exec "$node" "$transfer_command")
        if [[ $transfer_output == *"transfer=Ok"* ]]; then
          tx_hash=$(echo "$transfer_output" | grep -oP '(?<=tx_hash = ).*')
          echo "  Transfer of $value $token from $node is successful. (Hash: $tx_hash)"
        else
          echo "  Transfer of $value $token from $node has failed."
        fi
      fi
    else
      echo "  Threshold exceeded (Node: $node). Auto transfer is disabled."
    fi
  fi
}

# Function to get wallet balance and transfer funds if threshold is exceeded
get_and_transfer() {
  local node="$1"

  # Get the network list
  networks=$(ssh_exec "$node" "$CELLFRAME_PATH net list 2>/dev/null | grep -v 'networks:' | tr ',' '\n'")

  # Check if the network list retrieval was successful
  if [[ $? -ne 0 ]] || [[ -z "$networks" ]]; then
      echo "Failed to retrieve network list for node $node. Skipping..."
      echo "---------------------------------------------------------------"
      return
  fi

  # Loop through networks
  for net in $networks; do
    local token=$(get_token_ticker "$net")
    local master_wallet
    local threshold

    if [ "$net" == "Backbone" ]; then
      master_wallet="$CELL_MASTER_WALLET"
      threshold="$CELL_THRESHOLD"
    elif [ "$net" == "KelVPN" ]; then
      master_wallet="$KEL_MASTER_WALLET"
      threshold="$KEL_THRESHOLD"
    else
      echo "  Unknown network: $net. Skipping..."
      continue
    fi

    # Get fee_addr from the configuration file
    fee_addr=$(ssh_exec "$node" "grep 'fee_addr' $CONFIG_PATH/$net.cfg" | awk -F'=' '{print $2}')
    if [[ $? -ne 0 ]]; then continue; fi

    # Get wallet information
    wallet_info=$(ssh_exec "$node" "$CELLFRAME_PATH wallet info -addr $fee_addr")
    if [[ $? -ne 0 ]]; then continue; fi
    wallet_balance=$(echo "$wallet_info" | grep -A 3 'tokens:' | grep 'coins:' | awk '{print $2}')
    print_message "Node: $node"
    print_message "  Network: $net"
    print_message "  Wallet Balance: $wallet_balance $token"
    
    # Transfer funds if threshold is exceeded
    transfer_funds "$node" "$net" "$wallet_balance" "$threshold" "$master_wallet" "$token"
    
    print_message "---------------------------------------------------------------"
  done
}

# Loop to run the script repeatedly with a sleep interval
while true; do
  # Check for updates
  check_update

  # Loop through nodes and get their wallet information and transfer funds if needed
  for node in "${NODES[@]}"; do
    if is_node_online "$node"; then
      get_and_transfer "$node"
    fi
  done

  if [ "$VERBOSE" = true ]; then
    echo "Sleeping for $SLEEPTIME seconds..."
    echo "---------------------------------------------------------------"
  fi
  sleep "$SLEEPTIME"
done
