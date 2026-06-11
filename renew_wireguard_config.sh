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
auto_connect='true'
verbose='false'
token_override='none'
pia_pf='true'
pia_dns='true'
dip_token=''
conf_path='/etc/wireguard/pia.conf'
token_file='/etc/piavpn-manual/token'
region_file='/etc/piavpn-manual/region'

vecho() {
    if [[ "$verbose" == 'true' ]]; then
        echo "$@"
    fi
}

# This function allows you to check if the required tools have been installed.
check_tool() {
    local cmd="$1"
    local pkg="$2"
    if ! command -v "$cmd" >/dev/null; then
        echo "$cmd could not be found"
        echo "Please install $pkg"
        exit 1
    fi
}

usage() {
    local prog=${0##*/}
    cat << EOF
Generate wireguard configuration file.

Usage: $prog [options]

Options:
  -p <conf_path>  Path to save configuration file to (default: $conf_path)
  -c              Automatically connect after generation
  -v              Verbose printouts
  -h              Print this message and exit
EOF
}

parse_args() {
    # TODO: Make pia_pf option
    # TODO: Make dip_token option

    local OPTARG OPTIND opt
    while getopts 'p:cvh' opt; do
        case "$opt" in
            p) conf_path="$OPTARG";;
            c) auto_connect='true';;
            v) verbose='true';;
            h) usage
               exit;;
            *) usage >&2
               exit 1;;
        esac
    done
}

main() {
    parse_args "$@"

    check_tool wg-quick wireguard-tools
    check_tool curl curl
    check_tool jq jq

    # Only allow script to run as root
    if (( EUID != 0 )); then
        echo -e "This script must be run as root. Try again with 'sudo $0'" >&2
        exit 1
    fi

    local pia_token=''
    read -r pia_token < "$token_file"
    # TODO: Maybe an override

    # Protocol must be wireguard
    local wg_ip='' wg_cn=''
    {
        read # Meta servers
        read -r wg_ip wg_cn
    } < "$region_file"
    # TODO: Maybe an override?

    # Create ephemeral wireguard keys, that we don't need to save to disk.
    local priv_key="$(wg genkey)"
    local pub_key="$(echo "$priv_key" | wg pubkey)"

    # Authenticate via the PIA WireGuard RESTful API.
    # This will return a JSON with data required for authentication.
    # The certificate is required to verify the identity of the VPN server.
    # In case you didn't clone the entire repo, get the certificate from:
    # https://github.com/pia-foss/manual-connections/blob/master/ca.rsa.4096.crt
    # In case you want to troubleshoot the script, replace -s with -v.
    # TODO: Connect DIP stuff
    # TODO: Make these calls use --config to hide tokens
    echo "Trying to connect to the PIA WireGuard API on $wg_ip..."
    if [[ -z $dip_token ]]; then
        wireguard_json="$(curl -s -G \
            --connect-to "$wg_cn::$wg_ip:" \
            --cacert "ca.rsa.4096.crt" \
            --data-urlencode "pt=$pia_token" \
            --data-urlencode "pubkey=$pub_key" \
            "https://$wg_cn:1337/addKey" )"
    else
        wireguard_json="$(curl -s -G \
            --connect-to "$wg_cn::$wg_ip:" \
            --cacert "ca.rsa.4096.crt" \
            --user "dedicated_ip_$dip_token:$wg_ip" \
            --data-urlencode "pubkey=$pub_key" \
            "https://$wg_cn:1337/addKey" )"
    fi

    local wg_status='' dns_server='' peer_ip='' server_key='' server_port=''
    {
        read -r wg_status
        read -r dns_server
        read -r peer_ip
        read -r server_key
        read -r server_port
    } < <(jq -r '.status, .dns_servers[0], .peer_ip, .server_key,
                 .server_port' <<< "$wireguard_json")

    # Check if the API returned OK and stop this script if it didn't.
    if [[ "$wg_status" != 'OK' ]]; then
        >&2 echo 'Server did not return OK. Stopping now.'
        exit 1
    fi

    # Create the WireGuard config based on the JSON received from the API
    # In case you want this section to also add the DNS setting, please
    # start the script with PIA_DNS=true.
    # This uses a PersistentKeepalive of 25 seconds to keep the NAT active
    # on firewalls. You can remove that line if your network does not
    # require it.
    local dns_setting=''
    if [[ "$pia_dns" == 'true' ]]; then
        cat << EOF
Trying to set up DNS to $dns_server. In case you do not have resolvconf,
this operation will fail and you will not get a VPN. If you have issues,
start this script without PIA_DNS.
EOF
        dns_setting="DNS = $dns_server"
    fi

    if [[ "$auto_connect" == 'true' ]]; then
        # Multi-hop is out of the scope of this repo, but you should be able to
        # get multi-hop running with both WireGuard and OpenVPN by playing with
        # these scripts. Feel free to fork the project and test it out.
        echo 'Trying to disable a PIA WG connection in case it exists...'
        wg-quick down pia && echo 'PIA WG connection disabled!'
    fi

    echo -n "Trying to write $conf_path..."
    mkdir -p "$(dirname "$conf_path")"
    cat > "$conf_path" << EOF
[Interface]
Address = $peer_ip
PrivateKey = $priv_key
$dns_setting
[Peer]
PersistentKeepalive = 25
PublicKey = $server_key
AllowedIPs = 0.0.0.0/0
Endpoint = $wg_ip:$server_port
EOF
    echo 'OK!'

    if [[ "$auto_connect" == 'true' ]]; then
        # Start the WireGuard interface.
        # If something failed, stop this script.
        # If you get DNS errors because you miss some packages,
        # just hardcode /etc/resolv.conf to "nameserver 10.0.0.242".
        echo 'Trying to create the wireguard interface...'
        wg-quick up pia || exit 1
        cat << EOF
The WireGuard interface got created.
At this point, internet should work via VPN.
To disconnect the VPN, run:
--> wg-quick down pia <--
EOF
    fi

}

main "$@"

