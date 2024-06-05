#!/bin/bash
# Runner 0.19
# Node names
nodes=("cell1" "cell2" "kel1" "kel2" "kel3" "kel4")

# Path to cellframe-node-cli
cli_path="/opt/cellframe-node/bin/cellframe-node-cli"
dest_addresses_file="./dest_addresses.txt"
dest_addresses_url="https://raw.githubusercontent.com/nocdem/Cellframe/main/cellframe-community/Nocdem/dest_addresses.txt"

# Default fee and transaction value range
default_fee="0.01e+18"
min_value="0.0001e+18"
max_value="0.001e+18"
balance_threshold="0.001e+18"

# Default sleep time range (in minutes)
min_sleep_time=1
max_sleep_time=2

# URL of the script on GitHub
script_url="https://raw.githubusercontent.com/nocdem/Cellframe/main/cellframe-community/Nocdem/runner.sh"

# Function to check for script updates
check_for_updates() {
    local current_version=$(grep -m 1 -oP '^# Runner \K[0-9.]+' $0)
    local latest_version=$(curl -s $script_url | grep -m 1 -oP '^# Runner \K[0-9.]+')

    echo "Current version: $current_version"
    echo "Latest version on GitHub: $latest_version"

    if [ "$current_version" != "$latest_version" ]; then
        echo "New version $latest_version found. Updating script..."
        curl -s $script_url -o $0.tmp
        if [ $? -eq 0 ]; then
            mv $0.tmp $0
            chmod +x $0
            echo "Script updated to version $latest_version. Restarting..."
            exec $0 "$@"
        else
            echo "Failed to download the new version. Exiting..."
            rm -f $0.tmp
            exit 1
        fi
    else
        echo "Script is up to date."
    fi
}

# Function to download the destination addresses file
download_dest_addresses() {
    echo "Downloading destination addresses file..."
    curl -s $dest_addresses_url -o $dest_addresses_file.tmp
    if [ $? -eq 0 ]; then
        mv $dest_addresses_file.tmp $dest_addresses_file
        echo "Destination addresses file downloaded."
    else
        echo "Failed to download destination addresses file. Exiting..."
        rm -f $dest_addresses_file.tmp
        exit 1
    fi
}

# Function to check if the node is online
is_node_online() {
    local node=$1
    output=$(ssh $node "$cli_path version")
    if [[ $output == *"Error 111: Failed socket connection"* ]]; then
        echo "Node $node is rebooting. Skipping..."
        return 1
    fi
    return 0
}

# Function to get a random transaction value between min_value and max_value
get_random_value() {
    echo $(awk -v min=$min_value -v max=$max_value 'BEGIN{srand(); print min+rand()*(max-min)}')
}

# Function to get a random sleep time between min_sleep_time and max_sleep_time
get_random_sleep_time() {
    echo $(( RANDOM % (max_sleep_time - min_sleep_time + 1) + min_sleep_time ))
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

# Function to check the balance of a wallet
check_wallet_balance() {
    local node=$1
    local wallet=$2
    local balance_info=$(ssh $node "$cli_path wallet info -w $wallet")
    echo "Debug: Wallet info for $wallet on node $node:"
    echo "$balance_info"
    local balance=$(echo "$balance_info" | grep 'balance' | awk '{print $2}')
    echo "Debug: Extracted balance: $balance"
    awk -v balance=$balance -v threshold=$balance_threshold 'BEGIN{if(balance < threshold) exit 1; else exit 0}'
    return $?
}

# Function to send a transaction and handle retries
send_transaction() {
    local node=$1
    local network=$2
    local random_wallet=$3
    local random_dest=$4
    local token_ticker=$5
    local transaction_value=$(get_random_value)

    # Print only the necessary transaction details and node name
    echo "Sending transaction from: $random_wallet@$node to address: $random_dest with value: $transaction_value and fee: $default_fee"

    tx_output=$(ssh $node "$cli_path tx_create -net $network -chain main -value $transaction_value -token $token_ticker -to_addr $random_dest -from_wallet $random_wallet -fee $default_fee")

    if [[ "$tx_output" == *"transfer=Ok"* ]]; then
        return 0
    else
        return 1
    fi
}

# Function to send commands to a node via SSH
send_commands() {
    local node=$1

    # Check if the node is online
    if ! is_node_online $node; then
        return
    fi

    # Get the network list
    networks=$(ssh $node "$cli_path net list 2>/dev/null | grep -v 'networks:' | tr ',' '\n'")

    # Check if the network list retrieval was successful
    if [ -z "$networks" ]; then
        echo "Failed to retrieve network list for node $node. Skipping..."
        return
    fi

    # Loop through each network
    for network in $networks; do

        # Get the wallet list
        wallets=$(ssh $node "$cli_path wallet list 2>/dev/null | grep 'Wallet:' | awk '{print \$2}' | sed 's/.dwallet//'")

        # Check if wallets are available
        if [ -z "$wallets" ]; then
            echo "No wallets found on node $node for network $network"
            continue
        fi

        # Convert wallet list to an array
        wallet_array=($wallets)

        # Check if wallet array is not empty
        if [ ${#wallet_array[@]} -eq 0 ]; then
            echo "No wallets found on node $node for network $network"
            continue
        fi

        # Get the destination addresses for the network from the local file
        dest_addresses=$(grep "^$network," $dest_addresses_file | awk -F',' '{print $2}')

        # Convert destination addresses to an array
        dest_array=($dest_addresses)

        # Check if destination array is not empty
        if [ ${#dest_array[@]} -eq 0 ]; then
            echo "No destination addresses found for network $network"
            continue
        fi

        # Get a random wallet and destination address ensuring they are not the same
        for wallet in "${wallet_array[@]}"; do
            if check_wallet_balance $node $wallet; then
                random_wallet=$wallet
                break
            fi
        done
        if [ -z "$random_wallet" ]; then
            echo "No wallets with sufficient balance found on node $node for network $network"
            continue
        fi
        while true; do
            random_dest=${dest_array[RANDOM % ${#dest_array[@]}]}
            if [ "$random_dest" != "$random_wallet" ]; then
                break
            fi
        done

        # Get the token ticker for the network
        token_ticker=$(get_token_ticker $network)

        # Send the transaction and check for success
        if send_transaction $node $network $random_wallet $random_dest $token_ticker; then
            continue
        else
            # Retry with a different wallet and destination address
            for wallet in "${wallet_array[@]}"; do
                if check_wallet_balance $node $wallet; then
                    new_random_wallet=$wallet
                    break
                fi
            done
            if [ -z "$new_random_wallet" ]; then
                echo "No wallets with sufficient balance found on node $node for network $network"
                continue
            fi
            while true; do
                new_random_dest=${dest_array[RANDOM % ${#dest_array[@]}]}
                if [ "$new_random_dest" != "$new_random_wallet" ]; then
                    break
                fi
            done
            if ! send_transaction $node $network $new_random_wallet $new_random_dest $token_ticker; then
                echo "Transaction failed again. Skipping node $node."
                return
            fi
        fi
    done
}

# Main loop
while true; do
    # Check for script updates
    check_for_updates

    # Download the latest destination addresses file
    download_dest_addresses

    for node in "${nodes[@]}"; do
        send_commands $node
    done
    # Wait for a random period before the next iteration
    sleep_time=$(get_random_sleep_time)m
    echo "Sleeping for $sleep_time minutes..."
    sleep $sleep_time
done
