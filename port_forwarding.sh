#!/usr/bin/env bash
# Copyright (C) 2020 Private Internet Access, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# configurable inputs
token_file='/etc/piavpn-manual/token'
region_file='/etc/piavpn-manual/region'
pf_file='/etc/piavpn-manual/pf_data'

# This function allows you to check if the required tools have been installed.
check_tool() {
    cmd=$1
    if ! command -v "$cmd" >/dev/null; then
        echo "$cmd could not be found"
        echo "Please install $cmd"
        exit 1
    fi
}

usage() {
    local prog=${0##*/}
    cat << EOF
Create and renew port forwarding bindings.

Usage: $prog [options]

Options:
  -h              Print this message and exit
EOF
}

parse_args() {
    local OPTARG OPTIND opt
    while getopts 'h' opt; do
        case "$opt" in
            h) usage
               exit;;
            *) usage >&2
               exit 1;;
        esac
    done
}

main() {
    # Now we call the function to make sure we can use curl and jq.
    check_tool curl
    check_tool jq

    # Only allow script to run as root
    if (( EUID != 0 )); then
        echo -e "This script must be run as root. Try again with 'sudo $0'" >&2
        exit 1
    fi

    # Grab server ip and hostname from region_file
    # TODO OR override
    # TODO OR put all this in with the token
    # TODO Assumes wireguard, do the rest of them
    local server_ip='' server_host=''
    {
        read # Meta servers
        read -r server_ip server_host
    } < "$region_file"

    # TODO: Some sort of override maybe
    local pia_token=''
    read -r pia_token < "$token_file"

    # Check if the mandatory environment variables are set.
    if [[ -z $server_ip || -z $pia_token || -z $server_host ]]; then
        echo "This script requires 3 vars:"
        echo "server_ip  - the IP of your gateway"
        echo "server_host - name of the host used for SSL/TLS certificate verification"
        echo "pia_token   - the token you use to connect to the vpn services"
        echo
        echo "An easy solution is to just run get_token.sh and get_region.sh"
        echo "as it will guide you through getting the best server and"
        echo "also a token. Detailed information can be found here:"
        echo "https://github.com/pia-foss/manual-connections"
        exit 1
    fi

    # Check if terminal allows output, if yes, define colors for output
    if [[ -t 1 ]]; then
        ncolors=$(tput colors)
        if [[ -n $ncolors && $ncolors -ge 8 ]]; then
            red=$(tput setaf 1) # ANSI red
            green=$(tput setaf 2) # ANSI green
            nc=$(tput sgr0) # No Color
        else
            red=''
            green=''
            nc='' # No Color
        fi
    fi

    # The port forwarding system has required two variables:
    # PAYLOAD: contains the token, the port and the expiration date
    # SIGNATURE: certifies the payload originates from the PIA network.

    # Basically PAYLOAD+SIGNATURE=PORT. You can use the same PORT on all
    # servers.  The system has been designed to be completely decentralized, so
    # that your privacy is protected even if you want to host services on your
    # systems.

    # You can get your PAYLOAD+SIGNATURE with a simple curl request to any VPN
    # gateway, no matter what protocol you are using. Considering WireGuard has
    # already been automated in this repo, here is a command to help you get
    # your gateway if you have an active OpenVPN connection:
    # $ ip route | head -1 | grep tun | awk '{ print $3 }'
    # This section will get updated as soon as we created the OpenVPN script.

    # Get the payload and the signature from the PF API. This will grant you
    # access to a random port, which you can activate on any server you connect
    # to.
    # If you already have a signature, and you would like to re-use that port,
    # save the payload_and_signature received from your previous request
    # in the env var PAYLOAD_AND_SIGNATURE, and that will be used instead.
    # TODO Add option to force renewal
    local payload_and_signature=''
    if [[ -f "$pf_file" ]]; then
        echo -n 'Reading existing signature... '
        payload_and_signature="$(<"$pf_file")"
    else
        echo -n 'Getting new signature... '
        payload_and_signature="$(curl -s -m 5 \
            --connect-to "$server_host::$server_ip:" \
            --cacert "ca.rsa.4096.crt" \
            -G --data-urlencode "token=${pia_token}" \
            "https://${server_host}:19999/getSignature")"
    fi

    local pas_status='' signature='' payload=''
    {
        read -r pas_status
        read -r signature
        read -r payload
    } < <(jq -r '.status, .signature, .payload' <<< "$payload_and_signature")

    # Check if the payload and the signature are OK.
    # If they are not OK, just stop the script.
    if [[ "$pas_status" != 'OK' ]]; then
        echo -e "${red}The payload_and_signature variable does not contain an OK status.$nc"
        exit 1
    fi
    echo -e "${green}OK!$nc"

    # Save to pf_file
    # TODO don't need to do this if it was loaded
    cat > "$pf_file" <<< "$payload_and_signature"

    # We need to get the signature out of the previous response.
    # The signature will allow the us to bind the port on the server.

    # The payload has a base64 format. We need to extract it from the
    # previous response and also get the following information out:
    # - port: This is the port you got access to
    # - expires_at: this is the date+time when the port expires
    local payload_decode="$(base64 -d <<< "$payload")"
    local port='' expires_at=''
    {
        read -r port
        read -r expires_at
    } < <(jq -r '.port, .expires_at' <<< "$payload_decode")

    # The port normally expires after 2 months. If you consider
    # 2 months is not enough for your setup, please open a ticket.

    echo -ne "
    Signature $green$signature$nc
    Payload   $green$payload$nc

    --> The port is $green$port$nc and it will expire on $red$expires_at$nc. <--

    Trying to bind the port... "

    # Now we have all required data to create a request to bind the port.
    # We will repeat this request every 15 minutes, in order to keep the port
    # alive. The servers have no mechanism to track your activity, so they
    # will just delete the port forwarding if you don't send keepalives.
    local bind_port_response="$(curl -Gs -m 5 \
        --connect-to "$server_host::$server_ip:" \
        --cacert "ca.rsa.4096.crt" \
        --data-urlencode "payload=$payload" \
        --data-urlencode "signature=$signature" \
        "https://$server_host:19999/bindPort")"
    echo -e "${green}OK!$nc"

    # If port did not bind, just exit the script.
    # This script will exit in 2 months, since the port will expire.
    if [[ $(echo "$bind_port_response" | jq -r '.status') != "OK" ]]; then
        echo -e "${red}The API did not return OK when trying to bind port... Exiting.$nc"
        exit 1
    fi
    echo -e Forwarded port'\t'"$green$port$nc"
    echo -e Refreshed on'\t'"$green$(date)$nc"
    echo -e Expires on'\t'"$red$(date --date="$expires_at")$nc"
}

main "$@"

