#!/usr/bin/env bats

setup() {
    REPO_DIR="${BATS_TEST_DIRNAME}/.."
    PREPARE="${REPO_DIR}/prepare-image.sh"
}

@test "firstboot snapshots the canonical LAN deployment context" {
    grep -q 'appcore_detect_net_init' "$PREPARE"
    grep -q 'appcore_detect_net_write_cache "$DETECT_FILE"' "$PREPARE"
    grep -q 'appcore_detect_net_init "$DETECT_FILE" "${DOMAIN_NIC_NAME:-}"' "$PREPARE"
    grep -q 'search: \[${dom_domain}\]' "$PREPARE"
    grep -q 'This is preserved from DHCP' "$PREPARE"
}

@test "legacy netplan is static and has no automatic network services" {
    grep -q 'accept-ra: false' "$PREPARE"
    grep -q 'link-local: \[\]' "$PREPARE"
    grep -q "No 'routes' — legacy link is gateway-less by design" "$PREPARE"
    grep -q "No 'nameservers' — legacy link serves no DNS" "$PREPARE"
    grep -q 'The Legacy NIC requires a static IPv4/CIDR' "$PREPARE"
    grep -q 'The Legacy NIC must not carry a default route' "$PREPARE"
    grep -q 'The Legacy NIC must not carry DNS servers' "$PREPARE"
}

@test "dual-NIC renderer keeps LAN domain data and isolates LegacyZone" {
    helper="${BATS_TMPDIR}/write-netplan.sh"
    rendered="${BATS_TMPDIR}/60-smbproxy-init.yaml"
    awk '
        /^write_netplan_yaml\(\) \{/ {copy=1}
        /^config_network\(\) \{/ {copy=0}
        copy
    ' "$PREPARE" | sed "s#/etc/netplan/60-smbproxy-init.yaml#${rendered}#g" > "$helper"
    source "$helper"
    load_roles() {
        DOMAIN_NIC_NAME="eth0"
        DOMAIN_NIC_MAC="00:15:5d:0a:0a:1e"
        LEGACY_NIC_NAME="eth1"
        LEGACY_NIC_MAC="00:15:5d:00:04:28"
    }
    sudo() {
        "$@"
    }

    write_netplan_yaml static "10.20.30.40/24" "10.20.30.1" \
        "10.20.30.10" "factory.example" "172.29.137.5/24"

    grep -q 'addresses: \[10.20.30.40/24\]' "$rendered"
    grep -q 'addresses: \[10.20.30.10\]' "$rendered"
    grep -q 'search: \[factory.example\]' "$rendered"
    grep -q 'addresses: \[172.29.137.5/24\]' "$rendered"
    [ "$(grep -c 'to: default' "$rendered")" -eq 1 ]
    [ "$(grep -c 'nameservers:' "$rendered")" -eq 1 ]
    grep -q 'link-local: \[\]' "$rendered"
}

@test "successful silent netplan apply still produces operator feedback" {
    grep -q "Network configuration applied successfully" "$PREPARE"
}

@test "release preparation removes the lab seed identity" {
    grep -q 'appcore_hostname_apply_safe "smbproxy-1" ""' "$PREPARE"
    grep -q 'cloud-init clean --logs --seed' "$PREPARE"
    grep -q 'build-time FQDN remains active after generalization' "$PREPARE"
}

@test "generated firstboot, initial-setup, and MOTD scripts parse" {
    firstboot="${BATS_TMPDIR}/smbproxy-firstboot"
    initial="${BATS_TMPDIR}/smbproxy-init"
    motd="${BATS_TMPDIR}/15-smbproxy-net-status"
    awk '
        /^cat > \/usr\/local\/sbin\/smbproxy-firstboot <<'\''FBEOF'\''/ {copy=1; next}
        /^FBEOF$/ {copy=0}
        copy
    ' "$PREPARE" > "$firstboot"
    awk '
        /^cat > \/usr\/local\/sbin\/smbproxy-init <<'\''INITEOF'\''/ {copy=1; next}
        /^INITEOF$/ {copy=0}
        copy
    ' "$PREPARE" > "$initial"
    awk '
        /^cat > \/etc\/update-motd.d\/15-smbproxy-net-status <<'\''MOTDEOF'\''/ {copy=1; next}
        /^MOTDEOF$/ {copy=0}
        copy
    ' "$PREPARE" > "$motd"

    [ -s "$firstboot" ]
    [ -s "$initial" ]
    [ -s "$motd" ]
    bash -n "$firstboot"
    bash -n "$initial"
    sh -n "$motd"
}
