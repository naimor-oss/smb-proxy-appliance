#!/usr/bin/env bats

setup() {
    export SMBPROXY_ROLES_FILE="${BATS_TMPDIR}/nic-roles.env"
    export SMBPROXY_DETECT_FILE="${BATS_TMPDIR}/detected.env"
    cat > "$SMBPROXY_ROLES_FILE" <<'EOF'
DOMAIN_NIC_NAME="eth0"
DOMAIN_NIC_MAC="00:15:5d:0a:0a:1e"
LEGACY_NIC_NAME="eth1"
LEGACY_NIC_MAC="00:15:5d:00:04:28"
EOF
    source "${BATS_TEST_DIRNAME}/../smbproxy-sconfig.sh"
}

teardown() {
    unset SMBPROXY_ROLES_FILE SMBPROXY_DETECT_FILE \
          PROXY_DEFAULT_REALM PROXY_DEFAULT_DOMAIN_SHORT PROXY_DEFAULT_DC
}

@test "deployment detection is scoped to the persisted Domain NIC" {
    appcore_detect_net_init() {
        printf '%s|%s' "$1" "$2" > "${BATS_TMPDIR}/detector.args"
        APPCORE_DET_IFACE="$2"
        APPCORE_DET_IP="10.20.30.40"
        APPCORE_DET_GATEWAY="10.20.30.1"
        APPCORE_DET_DHCP_DNS="10.20.30.10"
        APPCORE_DET_DHCP_DOMAIN="factory.example"
        APPCORE_DET_PTR_FQDN="smbproxy-1.factory.example"
        APPCORE_DET_PTR_NAME="smbproxy-1"
        APPCORE_DET_PTR_DOMAIN="factory.example"
        APPCORE_DET_EFFECTIVE_DOMAIN="factory.example"
        APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE="dhcp"
    }

    refresh_proxy_network_context

    [ "$(<"${BATS_TMPDIR}/detector.args")" = "${SMBPROXY_DETECT_FILE}|eth0" ]
    [ "$APPCORE_DET_IFACE" = "eth0" ]
    [ "$APPCORE_DET_IP" = "10.20.30.40" ]
    [ "$APPCORE_DET_DHCP_DNS" = "10.20.30.10" ]
    [ "$APPCORE_DET_EFFECTIVE_DOMAIN" = "factory.example" ]
}

@test "domain defaults come from LAN DHCP and AD SRV discovery" {
    appcore_detect_net_init() {
        APPCORE_DET_IFACE="$2"
        APPCORE_DET_IP="10.20.30.40"
        APPCORE_DET_GATEWAY="10.20.30.1"
        APPCORE_DET_DHCP_DNS="10.20.30.10"
        APPCORE_DET_DHCP_DOMAIN="factory.example"
        APPCORE_DET_PTR_FQDN=""
        APPCORE_DET_PTR_NAME=""
        APPCORE_DET_PTR_DOMAIN=""
        APPCORE_DET_EFFECTIVE_DOMAIN="factory.example"
        APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE="dhcp"
    }
    timeout() {
        shift
        "$@"
    }
    dig() {
        echo "0 100 389 dc1.factory.example."
    }

    refresh_proxy_domain_defaults

    [ "$PROXY_DEFAULT_REALM" = "FACTORY.EXAMPLE" ]
    [ "$PROXY_DEFAULT_DOMAIN_SHORT" = "FACTORY" ]
    [ "$PROXY_DEFAULT_DC" = "dc1.factory.example" ]
}
