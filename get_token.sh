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
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null; then
        echo "$cmd could not be found"
        echo "Please install $cmd"
        exit 1
    fi
}

# This function creates a timestamp, to use for setting $TOKEN_EXPIRATION
timeout_timestamp() {
    date +"%c" --date='1 day' # Timestamp 24 hours
}

make_curl_creds() {
    local creds_file='/etc/piavpn-manual/pia_creds'
    local pia_user='', pia_pass=''
    {
        read -r pia_user
        read -r pia_pass
    } < "$creds_file"

    if [[ $? != 0 || -z "$pia_user" || -z "$pia_pass" ]]; then
        cat >&2 << EOF
If you want this script to automatically get a token from the Meta service,
please add your PIA username and password to the file '$creds_file'
Example:$ cat $creds_file
p0123456
xxx
EOF
        exit 1
    fi

    curl_creds_dir="$(mktemp -d /etc/piavpn-manual/.curl-XXXXXX)"
    chmod 700 "$curl_creds_dir"
    curl_creds="$curl_creds_dir/creds"
    touch "$curl_creds"
    chmod 600 "$curl_creds"

    cat > "$curl_creds" << EOF
form = "username=$pia_user"
form = "password=$pia_pass"
EOF
}

generate_token() {
    local curl_creds=''
    make_curl_creds

    local token_response="$(curl -s --location --request POST \
        --config "$curl_creds" \
        'https://www.privateinternetaccess.com/api/client/v2/token')"

    local token="$(jq -r '.token' <<< "$token_response")"
    if [[ "$token" == "" ]]; then
        echo "Could not authenticate with the login credentials provided!" >&2
        exit 1
    fi

    local token_file='/etc/piavpn-manual/token'
    touch "$token_file"
    chmod 600 "$token_file"
    token_expiration="$(timeout_timestamp)"
    cat > "$token_file" << EOF
$token
$token_expiration
EOF
}

main() {
    # Check for the required tools curl and jq
    check_tool curl
    check_tool jq

    # Only allow script to run as root
    if (( EUID != 0 )); then
        echo -e "This script must be run as root. Try again with 'sudo $0'" >&2
        exit 1
    fi

    generate_token
}

main

