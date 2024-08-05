#!/bin/bash
# Prerequisites: All nodes must have their root SSH keys installed in each of the nodes
# Add your node IPs into the nodes.cfg file
# Path to the Cellframe binary
CELLFRAME_PATH="/opt/cellframe-node/"

# Net and chain parameters
CHAIN="main"

# Block height threshold for synchronization warning
BLOCK_HEIGHT_THRESHOLD=50

# Configuration file path
CONFIG_FILE="nodes.cfg"

# Auto-sync configuration
AUTO_SYNC=false

# Function to read the configuration file and return the IP addresses
read_config() {
    local ips=()
    if [[ -f "$CONFIG_FILE" ]]; then
        while read -r line; do
            if [[ "$line" =~ ^auto_sync ]]; then
                AUTO_SYNC=$(echo "$line" | cut -d'=' -f2 | tr -d ' ')
            elif [[ ! -z "$line" && ! "$line" =~ ^# ]]; then
                ips+=("$line")
            fi
        done < "$CONFIG_FILE"
        echo "${ips[@]}"
    else
        echo "Config file not found. Exiting..."
        exit 1
    fi
}

# Read nodes from config file
NODES=($(read_config))
if [[ ${#NODES[@]} -gt 0 ]]; then
    echo "Config found, analyzing the nodes..."
else
    echo "No valid nodes found in the config file. Exiting..."
    exit 1
fi

# Function to execute SSH commands with error handling
ssh_exec() {
  local node="$1"
  local command="$2"
  result=$(ssh "$node" "$command" 2>&1) # Capture both stdout and stderr
  if [[ $? -ne 0 ]]; then
    echo "Error: Unable to connect to $node or execute command."
    echo "$result"  # Print the actual error message
    return 1
  else
    echo "$result"
  fi
}

get_block_heights() {
    declare -A NETWORK_HEIGHTS
    declare -A NODE_HEIGHTS
    declare -A NODE_NAMES
    declare -A ERRORS

    for IP in "${NODES[@]}"; do
        # Fetch the hostname
        hostname=$(ssh_exec "$IP" "hostname")
        if [[ $? -ne 0 ]]; then
            ERRORS["$IP"]="Error fetching hostname. Skipping node ($IP)."
            continue
        fi
        NODE_NAMES["$IP"]="$hostname"

        # Fetch all networks
        NETWORKS=$(ssh_exec "$IP" "$CELLFRAME_PATH/bin/cellframe-node-cli net list | grep -v 'networks:' | tr ',' '\n' | grep -v '^$'")
        
        # If NETWORKS is empty or contains errors, try to get the hostname and skip to the next node
        if [[ -z "$NETWORKS" || "$NETWORKS" =~ ^Error ]]; then
            NODE_NAMES["$IP"]="$hostname"
            ERRORS["$IP"]="Error fetching network list. Skipping node ($IP)."
            continue
        fi
        
        for NET in $NETWORKS; do
            block_info=$(ssh_exec "$IP" "$CELLFRAME_PATH/bin/cellframe-node-cli block list -net $NET -chain $CHAIN | tail -2")
            if [[ -z "$block_info" || "$block_info" =~ ^Error ]]; then
                ERRORS["$IP"]="Error fetching block information for network $NET."
                continue
            fi

            num_blocks=$(echo "$block_info" | grep -oP '\d+ blocks' | awk '{print $1}')
            if [[ -z "$num_blocks" ]]; then
                ERRORS["$IP"]="Error parsing number of blocks for network $NET."
                continue
            fi

            # Record block height for each network
            NETWORK_HEIGHTS["$NET"]="${NETWORK_HEIGHTS["$NET"]} $num_blocks"
            NODE_HEIGHTS["$IP:$NET"]=$num_blocks
        done
    done

    echo "Summary of highest block heights:"
    for NET in "${!NETWORK_HEIGHTS[@]}"; do
        # Find the highest block height for the network across all nodes
        heights=(${NETWORK_HEIGHTS[$NET]})
        highest_block=$(printf "%s\n" "${heights[@]}" | sort -nr | head -n 1)
        echo "Network: $NET"
        echo "    Highest block height: $highest_block"

        # Check and prompt for each node in the network
        for node in "${!NODE_HEIGHTS[@]}"; do
            if [[ $node == *":$NET" ]]; then
                node_ip=$(echo $node | cut -d':' -f1)
                node_block_height=${NODE_HEIGHTS[$node]}
                node_name=${NODE_NAMES[$node_ip]}
                echo "    $node_ip ($node_name): Block height: $node_block_height"
                if (( highest_block - node_block_height > BLOCK_HEIGHT_THRESHOLD )); then
                    echo "    Warning: $node_ip ($node_name) is $((highest_block - node_block_height)) blocks behind."
                    if [[ $AUTO_SYNC == true ]]; then
                        sync_nodes "$node_ip" "$node_name" "$NET" "$highest_block"
                    else
                        read -p "    Do you want to sync $node_ip ($node_name) from a higher node? (y/n): " answer
                        if [[ $answer == "y" ]]; then
                            sync_nodes "$node_ip" "$node_name" "$NET" "$highest_block"
                        else
                            echo "Sync cancelled for $node_ip ($node_name)."
                        fi
                    fi
                fi
            fi
        done
    done

    # Print errors if there are any
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        echo ""
        echo "Errors encountered:"
        for IP in "${!ERRORS[@]}"; do
            echo "    $IP: ${ERRORS[$IP]}"
        done
    fi
}

sync_nodes() {
    TARGET_IP=$1
    TARGET_NAME=$2
    NET=$3
    HIGHEST_BLOCK=$4

    # Set the network path based on the network type
    if [[ "$NET" == "Backbone" ]]; then
        NETWORK_PATH="/opt/cellframe-node/var/lib/network/scorpion"
    elif [[ "$NET" == "KelVPN" ]]; then
        NETWORK_PATH="/opt/cellframe-node/var/lib/network/kelvpn"
    else
        echo "Unknown network type: $NET. Skipping sync for $TARGET_IP ($TARGET_NAME)."
        return
    fi

    # Find a source node with the highest block height
    for node in "${!NODE_HEIGHTS[@]}"; do
        if [[ $node == *":$NET" && ${NODE_HEIGHTS[$node]} -eq $HIGHEST_BLOCK ]]; then
            SOURCE_IP=$(echo $node | cut -d':' -f1)
            SOURCE_NAME=${NODE_NAMES[$SOURCE_IP]}
            break
        fi
    done

    echo "Syncing $TARGET_IP ($TARGET_NAME) from $SOURCE_IP ($SOURCE_NAME)..."

    # Stop cellframe-node service on target node
    ssh_exec "$TARGET_IP" "sudo service cellframe-node stop"

    # Remove network directory on target node
    ssh_exec "$TARGET_IP" "sudo rm -r $NETWORK_PATH"

    # Rsync from source node to target node
    ssh_exec "$SOURCE_IP" "sudo rsync -rp --progress $NETWORK_PATH/ $TARGET_IP:$NETWORK_PATH/"

    # Restart cellframe-node service on target node
    ssh_exec "$TARGET_IP" "sudo service cellframe-node start"

    echo "Sync complete from $SOURCE_IP ($SOURCE_NAME) to $TARGET_IP ($TARGET_NAME)."
}

# Execute the default action: gather block heights and handle synchronization
get_block_heights
