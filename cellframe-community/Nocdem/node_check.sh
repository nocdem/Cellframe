#!/bin/bash

# Version information
SCRIPT_VERSION="1.9"

# Clear the terminal screen
clear
echo "---------------------------------------------------------------"

# Configuration file path
CONFIG_FILE="node_check.cfg"

# Check if configuration file exists, if not create it with default values
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file not found. Creating default configuration file."
    cat > "$CONFIG_FILE" << EOF
# Node Check Configuration
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
SCRIPT_URL="https://raw.githubusercontent.com/nocdem/Cellframe/main/cellframe-community/Nocdem/node_check.sh"

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

# Create an array of the last year (from today backward)
dates=()
for i in {0..365}; do
  dates+=("$(date --date="$i days ago" '+%a %b %_d')")
done

# Initialize totals
total_today_rewards_cell=0
total_yesterday_rewards_cell=0
total_wallet_balance_cell=0
total_today_rewards_kel=0
total_yesterday_rewards_kel=0
total_wallet_balance_kel=0

# Function to calculate daily rewards from today until the first empty variable
calculate_daily_rewards() {
  local history="$1"
  local token="$2"
  local stake_value="$3"
  local total_rewards=0
  local days_counted=0
  local last_7_days_rewards=0
  local today_reward=0
  local yesterday_reward=0

  # Iterate over the dates, starting from today and moving backward
  for day in "${dates[@]}"; do
    # Extract the daily reward
    daily_reward=$(echo "$history" | grep -A 22 "status: ACCEPTED" | grep -A 13 "$day" | grep -B 4 "source_address: reward collecting" | grep recv_coins | cut -d ":" -f 2 | awk '{ sum += $1 } END { print sum }')

    # Default daily_reward to 0 if empty
    daily_reward=${daily_reward:-0}

    # Add the daily reward to total_rewards
    total_rewards=$(echo "$total_rewards + $daily_reward" | bc -l)
    days_counted=$((days_counted + 1))

    # For the first 7 days starting from yesterday, add to last_7_days_rewards
    if [[ $days_counted -le 8 && $days_counted -ge 2 ]]; then
      last_7_days_rewards=$(echo "$last_7_days_rewards + $daily_reward" | bc -l)
    fi

    # Store the current day's reward and yesterday's reward with the token name
    if [[ $days_counted -eq 1 ]]; then
      today_reward=$daily_reward
      if [[ $token == "CELL" ]]; then
        total_today_rewards_cell=$(echo "$total_today_rewards_cell + $daily_reward" | bc)
      else
        total_today_rewards_kel=$(echo "$total_today_rewards_kel + $daily_reward" | bc)
      fi
    elif [[ $days_counted -eq 2 ]]; then
      yesterday_reward=$daily_reward
      if [[ $token == "CELL" ]]; then
        total_yesterday_rewards_cell=$(echo "$total_yesterday_rewards_cell + $daily_reward" | bc)
      else
        total_yesterday_rewards_kel=$(echo "$total_yesterday_rewards_kel + $daily_reward" | bc)
      fi
    fi
  done

  # Calculate average for the last 7 days if at least one day was counted
  if [[ $days_counted -ge 8 ]]; then
    average_last_7_days=$(echo "$last_7_days_rewards / 7" | bc -l)
  else
    average_last_7_days=$(echo "$last_7_days_rewards / ($days_counted - 1)" | bc -l)
  fi
  echo "   Today's reward: $today_reward $token (Yesterday was $yesterday_reward $token)"
  echo "   7 days: average $average_last_7_days $token"

  # Calculate APY
  if (( $(echo "$stake_value > 0" | bc -l) )); then
    apy=$(echo "scale=2; $average_last_7_days * 365 * 100 / $stake_value" | bc -l)
    echo "   APY: $apy% (based on 7 days average)"
  else
    echo "   APY: N/A (stake value is zero)"
  fi
}

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

# Function to get node status
get_node_info() {
  local node="$1"
  local net="$2"
  local chain="$3"
  local token="$4"
  local master_wallet="$5"
  local threshold="$6"

  # Get network status
  net_status=$(ssh_exec "$node" "$CELLFRAME_PATH net get status -net $net")
  if [[ $? -ne 0 ]]; then return; fi

  current_addr=$(echo "$net_status" | grep "current_addr" | awk '{print $2}')
  current=$(echo "$net_status" | grep "current:" | awk '{print $2}')
  percent=$(echo "$net_status" | grep "percent" | awk '{print $2}')

  # Check systemctl status
  systemctl_status=$(ssh_exec "$node" "systemctl status cellframe-node")
  if [[ $? -ne 0 ]]; then return; fi

  active_time=$(echo "$systemctl_status" | grep "Active: active (running)" | awk '{for (i=6; i<=NF; i++) printf $i " "; print ""}')
  echo "Node: $node ( $current_addr )"
  echo "  Active Time: $active_time"

  # Check autocollect status
  autocollect_status=$(ssh_exec "$node" "$CELLFRAME_PATH block autocollect status -net $net -chain $chain | grep active")
  if [[ $? -ne 0 ]]; then return; fi

  echo "  Autocollect status for Fees in network $net is active"
  echo "  Autocollect status for Rewards in network $net is active"

  echo "  Status: $current (% $percent)"

  # Get memory status
  mem_stats=$(ssh_exec "$node" "cat /proc/meminfo")
  if [[ $? -ne 0 ]]; then return; fi

  total_memory=$(echo "$mem_stats" | grep "MemTotal" | awk '{print $2}')
  free_memory=$(echo "$mem_stats" | grep "MemAvailable" | awk '{print $2}')
  used_memory=$((total_memory - free_memory))
  memory_utilization=$((used_memory * 100 / total_memory))

  # Get CPU status
  cpu_utilization=$(ssh_exec "$node" "$CELLFRAME_PATH stats cpu" | grep -oP 'Total: \K\d+')
  if [[ $? -ne 0 ]]; then return; fi

  echo "  Memory Utilization: $memory_utilization%   CPU Utilization: $cpu_utilization%"

  # Get fee_addr from the configuration file
  fee_addr=$(ssh_exec "$node" "grep 'fee_addr' $CONFIG_PATH/$net.cfg" | awk -F'=' '{print $2}')
  if [[ $? -ne 0 ]]; then return; fi

  # Retrieve transaction history for the fee_addr
  history=$(ssh_exec "$node" "$CELLFRAME_PATH tx_history -net $net -addr $fee_addr")
  if [[ $? -ne 0 ]]; then return; fi

  # Get certificate name
  cert_name=$(ssh_exec "$node" "cat $CONFIG_PATH/$net.cfg | grep 'blocks-sign-cert=' | sed 's/^.................//'")
  if [[ $? -ne 0 ]]; then return; fi

  # Get certificate status
  cert_status=$(ssh_exec "$node" "$CELLFRAME_PATH srv_stake list keys -net $net -cert $cert_name")
  if [[ $? -ne 0 ]]; then return; fi

  # Get stake value and multiply by 1000
  stake_value=$(echo "$cert_status" | grep -oP 'Stake value: \K[0-9.]+')
  stake_value=$(echo "$stake_value * 1000" | bc -l)

  # Calculate daily rewards for the fee_addr
  calculate_daily_rewards "$history" "$token" "$stake_value"

  # Get wallet information
  wallet_info=$(ssh_exec "$node" "$CELLFRAME_PATH wallet info -addr $fee_addr")
  if [[ $? -ne 0 ]]; then return; fi
  wallet_balance=$(echo "$wallet_info" | grep -A 3 'tokens:' | grep 'coins:' | awk '{print $2}')
  echo "  Wallet Balance: $wallet_balance $token"
  if [[ $token == "CELL" ]]; then
    total_wallet_balance_cell=$(echo "$total_wallet_balance_cell + $wallet_balance" | bc)
  else
    total_wallet_balance_kel=$(echo "$total_wallet_balance_kel + $wallet_balance" | bc)
  fi

  echo "  Stake Value: $stake_value $token"
  
  # Transfer funds if threshold is exceeded
  transfer_funds "$node" "$net" "$wallet_balance" "$threshold" "$master_wallet" "$token"
  
  echo "---------------------------------------------------------------"
}

# Loop through cell nodes and get their node information
for node in "${CELL_NODES[@]}"; do
  get_node_info "$node" "Backbone" "main" "CELL" "$CELL_MASTER_WALLET" "$CELL_THRESHOLD"
done

# Loop through kel nodes and get their node information
for node in "${KEL_NODES[@]}"; do
  get_node_info "$node" "KelVPN" "main" "KEL" "$KEL_MASTER_WALLET" "$KEL_THRESHOLD"
done

# Print summary report
echo "Summary Report"
echo "---------------------------------------------------------------"
echo "  Total Today's Rewards (CELL): $total_today_rewards_cell"
echo "  Total Yesterday's Rewards (CELL): $total_yesterday_rewards_cell"
echo "  Total Wallet Balance (CELL): $total_wallet_balance_cell"
echo "  Total Today's Rewards (KEL): $total_today_rewards_kel"
echo "  Total Yesterday's Rewards (KEL): $total_yesterday_rewards_kel"
echo "  Total Wallet Balance (KEL): $total_wallet_balance_kel"
echo "---------------------------------------------------------------"
