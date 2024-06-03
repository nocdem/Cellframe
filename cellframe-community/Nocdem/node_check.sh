#!/bin/bash

# All ssh keys must be installed on the master computer
# Add all nodes to /etc/hosts

# Clear the terminal screen
clear
echo "---------------------------------------------------------------"

# Define arrays for node names
cell_nodes=("cell1" "cell2")
kel_nodes=("kel1" "kel2" "kel3" "kel4")

# Paths 
CELLFRAME_PATH="/opt/cellframe-node/bin/cellframe-node-cli"
CONFIG_PATH="/opt/cellframe-node/etc/network"

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

    # For the first 7 days, add to last_7_days_rewards
    if [[ $days_counted -le 7 ]]; then
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
  if [[ $days_counted -ge 7 ]]; then
    average_last_7_days=$(echo "$last_7_days_rewards / 7" | bc -l)
  else
    average_last_7_days=$(echo "$last_7_days_rewards / $days_counted" | bc -l)
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
  ssh "$node" "$command" 2>/dev/null
  if [[ $? -ne 0 ]]; then
    echo "    Error: Unable to connect to $node or execute command."
    return 1
  fi
}

# Function to get node status
get_node_info() {
  local node="$1"
  local net="$2"
  local chain="$3"
  local token="$4"

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
  echo "---------------------------------------------------------------"
}

# Loop through cell nodes and get their node information
for node in "${cell_nodes[@]}"; do
  get_node_info "$node" "Backbone" "main" "CELL"
done

# Loop through kel nodes and get their node information
for node in "${kel_nodes[@]}"; do
  get_node_info "$node" "KelVPN" "main" "KEL"
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
