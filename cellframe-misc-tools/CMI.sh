#!/bin/bash

LOG="/tmp/CMI.log"

check_root() {
    if [[ $EUID -ne 0 ]] ; then
        echo "Need root rights, exiting..."
        exit 1
    else
        showinfo
    fi
}

showinfo() {
    cat << EOF

    ########################################################################
    ########################################################################
    ##                                                                    ##
    ##  Cellframe Masternode Installer // CMI                             ##
    ##  __________________________________________                        ##
    ##                                                                    ##
    ##  Welcome to Cellframe Mastenode installation script.               ##
    ##                                                                    ##
    ##  This script tries to install the latest Cellframe Node and        ##
    ##  setup it as a master node to your computer with minimal           ##
    ##  as possible user input.                                           ##
    ##                                                                    ##
    ##  PREREQUISITES:                                                    ##
    ##                                                                    ##
    ##      1.) Seed phrase from your wallet (24 words)                   ##
    ##                                                                    ##
    ##  Problems may occur and therefore the creator of this script       ##
    ##  won't be responsible about any lost funds or wallets if/when      ##
    ##  using this script!                                                ##
    ##                                                                    ##
    ##  Issues with the script? Ping @CELLgainz in Telegram :)            ##
    ##                                                                    ##
    ########################################################################
    ########################################################################
EOF
    read -p "Are you sure you want to continue? (Y/N) " confirm
    if [[ $confirm =~ ^[yY]$ ]]; then
        clear
        echo "--- Continuing in 5 seconds, you may still exit with CTRL+C..."
        echo "--- Logging to $LOG"
        sleep 5
        check_node_presence
    else
        echo "--- Exiting..."
        exit 1
    fi
}

check_node_presence() {
    NODE_PATH="/opt/cellframe-node"
    if [[ -d $NODE_PATH ]]; then
        echo "--- Detected $NODE_PATH path, this script is meant for completely clean installs only. Exiting..."
        exit 1
    else
        check_deps
    fi
}

check_deps() {
    echo "--- Checking necessary dependencies..."
    DEPS=(sed apt wget sha256sum wc)
    for i in ${DEPS[@]}
    do
        if [[ $(command -v $i) ]]; then
            echo -e "\t==> $i found, continuing..."
        else
            echo -e "\t==> $i not found, exiting..."
            exit 1
        fi
    done
    download_and_install_node
}

download_and_install_node() {
    echo "--- Downloading latest version of Cellframe node..."
    LATEST_VERSION=$(wget -qO- https://pub.cellframe.net/linux/cellframe-node/master/ | grep -oP "\Kcellframe-node-5.2.[0-9]{3}-updtr-amd64.deb" | sort | tail -n1)
    wget -q https://pub.cellframe.net/linux/cellframe-node/master/$LATEST_VERSION
    DEBIAN_FRONTEND=noninteractive apt install -y -qq ./$LATEST_VERSION > /dev/null #stdout to nothingness!
    rm $LATEST_VERSION
    echo "--- Restarting cellframe-node.service..."
    configure_node
}

configure_node() {
    NODE_CONFIG_FILE="/opt/cellframe-node/etc/cellframe-node.cfg"
    BACKBONE_CONFIG_FILE="/opt/cellframe-node/etc/network/Backbone.cfg"
    declare -x -g NODE_ADDR=$(sh -c "/opt/cellframe-node/bin/cellframe-node-cli net -net Backbone get status | grep -oP '[0-9A-Z]{4}::[0-9A-Z]{4}::[0-9A-Z]{4}::[0-9A-Z]{4}'")
    echo "--- Modifying node configuration..."
    sed -i "s/^auto_online=.*/auto_online=true/g" $NODE_CONFIG_FILE
    sed -i "0,/enabled=false/s//enabled=true/" $NODE_CONFIG_FILE
    sed -i "s/^auto_proc=.*/auto_proc=true/g"  $NODE_CONFIG_FILE
    sed -i "/^\[general\]/a node_addr_type=static" $NODE_CONFIG_FILE
    sed -i "/^\[general\]/a node-addr=$NODE_ADDR" $NODE_CONFIG_FILE
    echo "--- Modifying Backbone configuration..."
    sed -i "s/^node-role=.*/node-role=master/g"  $BACKBONE_CONFIG_FILE
    sed -i "s/^#blocks-sign-cert=.*/blocks-sign-cert=$CERT/g" $BACKBONE_CONFIG_FILE
    sed -i "s/^#fee_addr=.*/fee_addr=$WALLETADDRESS/g" $BACKBONE_CONFIG_FILE
    read -p "--- Input the amount of CELL tokens which will be automatically collected after a desired amount is accumulated: " collectamount
    if [[ $collectamount =~ ^[0-9]*$ ]]; then
        echo "--- Setting to $collectamount of CELL tokens..."
    else
        echo "--- Unsupported value, using default value of 2 \$CELL tokens"
        collectamount=2
    fi
    sed -i "/^\[esbocs\]/a set_collect_fee=$collectamount" $BACKBONE_CONFIG_FILE
    systemctl restart cellframe-node.service
    echo "--- Waiting 30 seconds for node to restart..."
    sleep 30
    create_cert
}

create_cert() {
    read -p "--- Input a desired name to your certificate: " cert
        if [[ $cert =~ ^[a-zA-Z0-9]*$ ]]; then
            echo "--- Your certificate backbone.$cert will be created..."
            sh -c "/opt/cellframe-node/bin/cellframe-node-tool cert create backbone.$cert sig_dil"
            declare -x -g CERT="backbone.$cert"
            create_wallet
        else
            echo "--- Supported characters are a-z, A-Z, 0-9. No spaces."
            create_cert
        fi
}

create_wallet() {
    read -p "--- Input a desired name to your wallet: " walletname
        if [[ $walletname =~ ^[a-zA-Z0-9]*$ ]]; then
            echo "--- Your wallet $walletname will be created..."
            declare -x -g WALLETNAME=$walletname
            get_seed
        else
            echo "--- Supported characters are a-z, A-Z, 0-9. No spaces."
            create_wallet
        fi
}
get_seed() {
    read -p "--- Input your 24 word seed phrase: " words
        count=$(echo $words | wc -w)
        if [[ $count -eq 24 ]]; then
            SHA256=$(echo -n $words | tr -d [:blank:] | sha256sum | cut -d " " -f1)
            echo "--- Your SHA256SUM of seed phrase is: $SHA256"
            sh -c "/opt/cellframe-node/bin/cellframe-node-cli wallet new -w $WALLETNAME -sign sig_dil -restore 0x$SHA256 -force | tee -a $LOG"
            declare -x -g WALLETADDRESS=$(sh -c "/opt/cellframe-node/bin/cellframe-node-cli wallet info -w $WALLETNAME -net Backbone | grep -oP 'addr: \K.*$'")
            create_validator_order
        else
            echo "--- Not a 24 word seed phrase, your seed phrase had $count words!"
            get_seed
        fi
}

create_validator_order() {
    echo "--- Creating order for the validator fee... (using the recommended value of 0.05 \$CELL)"
    sh -c "/opt/cellframe-node/bin/cellframe-node-cli srv_stake order create -net Backbone -value 0.05e+18 -cert $CERT | tee -a $LOG"
    publish_node
}

publish_node() {
    IP=$(ip route get 1 | grep -oP 'src \K([0-9]{1,3}[\.]){3}[0-9]{1,3}')
    sh -c "/opt/cellframe-node/bin/cellframe-node-cli node add -net Backbone -addr $NODE_ADDR -cell 0x0000000000000000 -ipv4 $IP -port 8079"
    check_wallet_balance
}

check_wallet_balance() {
    echo "--- Checking your wallet balance..."
    BALANCE=$(sh -c "/opt/cellframe-node/bin/cellframe-node-cli wallet info -w test -net Backbone | grep -oP '\(\d+\) mCELL' | tr -d '()' | cut -d ' ' -f 1 | wc -m")
    if [[ $BALANCE -lt 21 ]]; then
        echo "--- Looks like you don't have enough mCELL on your wallet. It's possible that node is still syncing wallet data. Will wait for 5 minutes..."
        sleep 5m
        check_wallet_balance
    else
        lock_mcell
    fi
}

lock_mcell() {
    echo "--- OK, time to lock your mCELL for mastenode..."
    read -p "Enter the amount which you want to lock for your mastenode (no decimals): " MCELL
    if [[ ! $MCELL =~ ^[0-9]{2,}$ ]]; then
        echo "--- Invalid amount of tokens! Let's try again..."
        lock_mcell
    else
        echo "--- Delegating stake..."
        sh -c "/opt/cellframe-node/bin/cellframe-node-cli srv_stake delegate -cert $CERT -net Backbone -wallet $WALLETADDRESS -value $MCELL.0e+18 -node_addr $NODE_ADDR -fee 0.05e+18 | tee -a $LOG"
        msg_ready
    fi
}

msg_ready() {
    echo "--- Everything done, please post your stake transaction hash to the Cellframe Support Telegram group"
    cat $LOG
}

check_root