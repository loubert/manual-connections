#!/bin/bash
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

# --- script variables

curl_creds_dir=''

# --- script functions

# Trap function to cleanup on exit
cleanup() {
    if [[ -n "$curl_creds_dir" ]]; then
        rm -rf "$curl_creds_dir"
    fi
}

# This function allows you to check if the required tools have been installed.
check_tool() {
  cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "$cmd could not be found"
    echo "Please install $cmd"
    exit 1
  fi
}

make_curl_creds() {
    local token_file='/etc/piavpn-manual/token'
    local pia_token=''
    read -r pia_token < "$token_file"
    if [[ $? -ne 0 || -z "$pia_token" ]]; then
        cat >&2 << EOF
If you want this script to automatically retrieve dedicated IP location details
from the Meta service, first generate a token with get_token.sh
Example:$ sudo ./get_token.sh
EOF
        exit 1
    fi

    local dip_token_file='/etc/piavpn-manual/dip_token'
    local dip_token=''
    read -r dip_token < "$dip_token_file"
    if [[ $? -ne 0 || -z "$dip_token" ]]; then
        cat >&2 << EOF
If you want this script to automatically retrieve dedicated IP location details
from the Meta service, save your DIP token to the file '$dip_token_file'
Example:$ cat $dip_token_file
DIP1a2b3c4d5e6f7g8h9i10j11k12l13
EOF
        exit 1
    fi

    curl_creds_dir="$(mktemp -d /etc/piavpn-manual/.curl-XXXXXX)"
    chmod 700 "$curl_creds_dir"
    curl_creds="$curl_creds_dir/creds"
    touch "$curl_creds"
    chmod 600 "$curl_creds"

    cat > "$curl_creds" << EOF
header = "Authorization: Token $pia_token"
data-raw = "{ \"tokens\":[\"$dip_token\"] }"
EOF
}

generate_dip_response() {
    local curl_creds=''
    make_curl_creds

    local dip_response="$(curl -s --location --request POST \
        'https://www.privateinternetaccess.com/api/client/v2/dedicated_ip' \
        --header 'Content-Type: application/json' \
        --config "$curl_creds")"

    local dip_status='null'
    local dip_address='null'
    local dip_hostname='null'
    local dip_expiration='null'
    local dip_id='null'
    {
        read -r dip_status
        read -r dip_address
        read -r dip_hostname
        read -r dip_expiration
        read -r dip_id
    } < <(jq -r '.[0] | .status, .ip, .cn, .dip_expire, .id' <<< "$dip_response")

    if [[ "$dip_status" != "active" ]]; then
        echo "Could not validate the dedicated IP token provided!" >&2
        exit 1
    fi
    local key_hostname="dedicated_ip_$dip_token"
    dip_expiration="$(date -d "@$dip_expiration")"

    local pf_capable='true'
    if [[ "$dip_id" == us_* ]]; then
        pf_capable='false'
    fi

    local dip_address_file='/etc/piavpn-manual/dip_address'
    touch "$dip_address_file"
    chmod 600 "$dip_address_file"
    cat > "$dip_address_file" << EOF
$dip_address
$dip_hostname
$key_hostname
$dip_expiration
$pf_capable
EOF
}

main() {
    # Now we call the function to make sure we can use curl and jq.
    check_tool curl
    check_tool jq

    # Only allow script to run as root
    if (( EUID != 0 )); then
        echo -e "This script needs to be run as root. Try again with 'sudo $0'"
        exit 1
    fi

    generate_dip_response
}

trap cleanup EXIT
main

