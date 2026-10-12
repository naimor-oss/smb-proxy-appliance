#!/usr/bin/env bats
# The first-boot loader reads the detection cache with appcore_kv_load, which
# refuses unknown keys. This pins the contract between appliance-core's cache
# writer and this appliance's key list: a field the library adds must not make
# the whole file unreadable (which would silently drop the NIC inventory).

setup() {
    CORE="${BATS_TEST_DIRNAME}/../../appliance-core/lib"
    PREPARE="${BATS_TEST_DIRNAME}/../prepare-image.sh"
    DETECT_FILE="${BATS_TEST_TMPDIR}/detected.env"
    ROLES_FILE="${BATS_TEST_TMPDIR}/nic-roles.env"
    # The generated first-boot script, cut down to the key list and loaders.
    awk '
        /^cat > \/usr\/local\/sbin\/smbproxy-init <<'\''INITEOF'\''/ {copy=1; next}
        /^INITEOF$/ {copy=0}
        copy
    ' "$PREPARE" | awk '
        /^# Keys the first-boot detection cache may contain/ {take=1}
        take {print}
        take && /^load_detect_env\(\) \{/ {infn=1}
        infn && /^}/ {exit}
    ' > "${BATS_TEST_TMPDIR}/loader.sh"
    [ -s "${BATS_TEST_TMPDIR}/loader.sh" ]
}

@test "the loader reads the cache the current appliance-core writes, NIC inventory included" {
    # shellcheck disable=SC1091
    source "$CORE/kvstate.sh"
    # shellcheck disable=SC1091
    source "$CORE/detect-net.sh"
    APPCORE_DET_IFACE=eth0 APPCORE_DET_IP=10.20.30.40 APPCORE_DET_GATEWAY=10.20.30.1
    APPCORE_DET_DHCP_DNS=10.20.30.10 APPCORE_DET_DHCP_DOMAIN=factory.example
    APPCORE_DET_PTR_FQDN="" APPCORE_DET_PTR_NAME="" APPCORE_DET_PTR_DOMAIN=""
    appcore_detect_net_write_cache "$DETECT_FILE"
    cat >> "$DETECT_FILE" <<'EOT'
DET_NIC_COUNT="1"
NIC0_NAME="eth0"
NIC0_MAC="00:15:5d:0a:0a:1e"
NIC0_STATE="up"
NIC0_IP4="10.20.30.40/24"
NIC0_DHCP="yes"
EOT

    # shellcheck disable=SC1090
    source "${BATS_TEST_TMPDIR}/loader.sh"
    appcore_detect_net_init() { :; }
    load_roles() { :; }   # unrelated to the cache; defined outside the extracted range
    load_detect_env

    [ "$DET_NIC_COUNT" = "1" ]
    [ "$NIC0_NAME" = "eth0" ]
    [ "$DET_DEFAULT_IFACE" = "eth0" ]
    [ "$DET_DEFAULT_IP" = "10.20.30.40" ]
    [ "$DET_DHCP_DOMAIN" = "factory.example" ]
}
