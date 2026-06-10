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

# script globals
serverlist_url='https://serverlist.piaservers.net/vpninfo/servers/v6'
latency_file='/etc/piavpn-manual/latency_list'
tmp_latency_dir=''
max_parallel=10

# configurable inputs
preferred_region='none'
max_timeout=0.5
protocol='wg'
require_pf='false'
verbose='false'

# Trap function to cleanup on exit
cleanup() {
    if [[ -d "$tmp_latency_dir" ]]; then
        rm -rf "$tmp_latency_dir"
    fi
}

# This function allows you to check if the required tools have been installed.
check_tool() {
    cmd="$1"
    if ! command -v "$cmd" >/dev/null; then
        echo "$cmd could not be found"
        echo "Please install $cmd"
        exit 1
    fi
}

# This function checks the latency you have to a specific server.
probe_server_latency() {
    local server_ip="$1"
    local latency="$(LC_NUMERIC=en_US.utf8 curl -o /dev/null -s \
        --connect-timeout "$max_timeout" \
        --write-out "%{time_connect}" \
        "http://$server_ip:443")"
    if [[ "$latency" =~ ^0*\.?0*$ ]]; then
        echo '999'
    else
        echo "$latency"
    fi
}

usage() {
    local prog=${0##*/}
    cat << EOF
Find the best region server to connect to.

Usage: $prog [options]

Options:
  -r <region>    Preferred region to use (default: $preferred_region)
  -t <timeout>   Maximum timeout to allow, in seconds (default: $max_timeout)
  -p <protocol>  VPN Protocol to use: meta, wg, ovpntcp, ovpnudp (default: $protocol)
  -f             Filter out non-port-forwarding servers (default: $require_pf)
  -v             Verbose printouts
  -h             Print this message and exit
EOF
}

parse_args() {
    local OPTARG OPTIND opt
    while getopts 'r:l:p:fvh' opt; do
        case "$opt" in
            r) preferred_region="$OPTARG";;
            l) max_timeout="$OPTARG";;
            p) protocol="$OPTARG";;
            f) require_pf='true';;
            v) verbose='true';;
            h) usage
               exit;;
            *) usage >&2
               exit 1;;
        esac
    done

    if [[ "$protocol" != @('meta'|'wg'|'ovpntcp'|'ovpnudp') ]]; then
        echo "Invalid protocol. Must be one one meta, wg, ovpntcp, ovpnudp" >&2
        exit 1
    fi
}

main() {
    # Parse arguments
    parse_args "$@"

    # Check for availability of needed tools
    check_tool curl
    check_tool jq

    # Only allow script to run as root
    if (( EUID != 0 )); then
        echo "This script needs to be run as root. Try again with 'sudo $0'" >&2
        exit 1
    fi

    # Renew latency file
    rm -f "$latency_file"
    touch "$latency_file"

    # Get all region data
    local region_data=''
    read -r region_data < <(curl -s "$serverlist_url")

    # Filter based on region
    if [[ "$preferred_region" != 'none' ]]; then
        region_data="$(jq -cr --arg REGION_ID "$preferred_region" \
                       '{"regions":[.regions[] | select(.id==$REGION_ID)]}' \
                       <<< "$region_data")"
    fi

    # Filter based on port-forwarding
    if [[ "$require_pf" == 'true' ]]; then
        region_data=$(jq -cr '{"regions":[.regions[]
                               | select(.port_forward==true)]}' \
                               <<< "$region_data")
    fi

    local num_regions="$(jq -cr '.regions | length' <<< $region_data)"
    if (( num_regions == 0 )); then
        cat >&2 << EOF
No regions available. Double check spelling of any specified region.
If port-forwarding required, make sure any specified region is not in the US.
EOF
        exit 1
    fi

    # Check the latencies of the remaining servers
    tmp_latency_dir=''
    tmp_latency_dir="$(mktemp -d /etc/piavpn-manual/.latency-XXXXXX)"
    chmod 700 "$tmp_latency_dir"

    local server_ip='' region_id=''
    while { read -r server_ip; read -r region_id; }; do
        echo "$(probe_server_latency "$server_ip") $server_ip $region_id" \
             > "$tmp_latency_dir/$server_ip" &
        while (( $(jobs -rp | wc -l) >= max_parallel )); do
            wait -n
        done
    done < <(jq -r --arg PROTO "$protocol" \
             '.regions[] | (.servers[$PROTO][0].ip, .id)' <<< "$region_data")

    wait

    cat "$tmp_latency_dir"/* | sort -n > "$latency_file"
}

trap cleanup EXIT
main "$@"

