#!/usr/bin/env bash
#
# HISTORICAL — DO NOT RUN.
#
# This file is preserved as the original single-script sketch that drove the
# design of the smb-proxy-appliance two-script layout. The working scripts
# that supersede it are:
#
#   ../prepare-image.sh        — vendor-neutral image prep (no realm, no
#                                credentials, no backend IP baked in).
#   ../smbproxy-sconfig.sh     — whiptail TUI + headless CLI: NIC role
#                                assignment, AD join, backend SMB1 mount,
#                                frontend SMB3 share, diagnostics, services.
#
# The intent and the locking-strict frontend stanza in this sketch carried
# directly into smbproxy-sconfig. The deployment-specific pieces here
# (WS2008/WS2025 IPs, share names, credentials) became sconfig prompts.
#
# ------------------------------------------------------------------------------
set -euo pipefail

# ==============================================================================
# CONFIGURATION VARIABLES - Edit these before running
# ==============================================================================
# WS2008 Backend (SMB1 Target)
WS2008_IP="172.29.137.1"    # Dedicated Link IP
WS2008_SHARE="ProfitFab$"
WS2008_DOMAIN="LEGACY"
WS2008_USER="pfuser"
WS2008_PASS="<ROTATED-2026-05-01-see-internal-vault>"  # original literal removed; cred rotated in production. See dev-commons/PUBLISH-CHECKLIST.md.

# WS2025 Active Directory Domain (Frontend)
DOMAIN_FQDN="naimor.naimorinc.com"
DOMAIN_SHORT="NAIMOR"      # NetBIOS name (pre-Windows 2000 domain name)
DC_IP="192.168.0.18"       # Domain Network IP
AD_ADMIN_USER="NMAdmin"

# Proxy Configuration
PROXY_MOUNT="/mnt/profitfab$"
PROXY_SHARE_NAME="ProfitFab$"
PROXY_ACCESS_GROUP="NAIMOR\ProfitFab Users"  # Domain security group controlling who can access legacy share
PROXY_FRONTEND_USER="pfuser"

# ==============================================================================
# INITIALIZATION & CREDENTIAL GATHERING
# ==============================================================================
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: This script must be run as root." >&2
  exit 1
fi

echo "Please enter the password for the WS2025 Domain Admin (${DOMAIN_SHORT}\\${AD_ADMIN_USER}):"
read -rs AD_ADMIN_PASS
echo ""

# ==============================================================================
# 1. SYSTEM CLEANUP (Minimal File Server Baseline)
# ==============================================================================
echo "[1/8] Removing unnecessary packages..."
# Remove services that expand the attack surface on a hardened file server
apt-get remove --purge -y avahi-daemon rpcbind cups cups-daemon x11-common || true
apt-get autoremove -y

# ==============================================================================
# 2. INSTALLATION OF REQUIRED PACKAGES
# ==============================================================================
echo "[2/8] Installing Samba, Winbind, and Kerberos components..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  samba winbind smbclient cifs-utils krb5-user libnss-winbind libpam-winbind ntpdate

# Ensure time is perfectly synchronized with the WS2025 Domain Controller (Critical for Kerberos)
echo "Synchronizing time with Domain Controller..."
ntpdate -u "${DC_IP}" || echo "WARNING: Time sync failed. Ensure chrony/systemd-timesyncd is configured to use the DC."

# ==============================================================================
# 3. KERBEROS CONFIGURATION
# ==============================================================================
echo "[3/8] Configuring Kerberos..."
DOMAIN_REALM="${DOMAIN_FQDN^^}"

cat <<EOF > /etc/krb5.conf
[libdefaults]
    default_realm = ${DOMAIN_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${DOMAIN_REALM} = {
        kdc = ${DOMAIN_FQDN}
        admin_server = ${DOMAIN_FQDN}
    }

[domain_realm]
    .${DOMAIN_FQDN,,} = ${DOMAIN_REALM}
    ${DOMAIN_FQDN,,} = ${DOMAIN_REALM}
EOF

# ==============================================================================
# 4. SAMBA CONFIGURATION (WS2025 Hardened Baseline)
# ==============================================================================
echo "[4/8] Configuring Samba and Winbind..."
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# Note: As a member server, Samba seamlessly interoperates with Domain Functional Level 2016. 
# DFL restrictions only apply when provisioning Samba *as* a Domain Controller.
cat <<EOF > /etc/samba/smb.conf
[global]
    # Domain Join Configuration
    workgroup = ${DOMAIN_SHORT}
    realm = ${DOMAIN_REALM}
    security = ads
    
    # Winbind Identity Mapping (RID backend for single domains)
    winbind use default domain = yes
    winbind enum users = yes
    winbind enum groups = yes
    winbind refresh tickets = yes
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config ${DOMAIN_SHORT} : backend = rid
    idmap config ${DOMAIN_SHORT} : range = 10000-999999
    template shell = /bin/bash

    # WS2025 Security & Cryptography Baselines
    # Force SMB3 for all domain communications; WS2025 defaults to rejecting older dialects.
    server min protocol = SMB3
    client min protocol = SMB3
    
    # Enforce packet signing (Mandatory in WS2025) and disable insecure NTLM where possible
    server signing = mandatory
    client signing = mandatory
    server smb encrypt = desired
    client smb encrypt = desired
    ntlm auth = ntlmv2-only
    restrict anonymous = 2
    kerberos method = secrets and keytab
    
    # Disable NetBIOS (Deprecated in WS2025)
    disable netbios = yes
    smb ports = 445

[${PROXY_SHARE_NAME}]
    path = ${PROXY_MOUNT}
    read only = no
    guest ok = no
    valid users = @"${PROXY_ACCESS_GROUP}"
    
    # Map all incoming AD user operations to the local backend proxy account
    force user = ${PROXY_FRONTEND_USER}
    force group = ${PROXY_FRONTEND_USER}
    
    # Strict Locking Mechanics for ISAM/.TPS Databases
    oplocks = no
    level2 oplocks = no
    strict locking = yes
    kernel oplocks = no
    posix locking = yes
EOF

# ==============================================================================
# 5. DOMAIN JOIN
# ==============================================================================
echo "[5/8] Joining the WS2025 Active Directory Domain..."
# Generate a temporary Kerberos ticket to authorize the join
echo "${AD_ADMIN_PASS}" | kinit "${AD_ADMIN_USER}@${DOMAIN_REALM}"

# Execute the join sequence
net ads join -k

# ==============================================================================
# 6. NSSWITCH CONFIGURATION (Identity Resolution)
# ==============================================================================
echo "[6/8] Updating NSSwitch for AD identity resolution..."
sed -i 's/^passwd:.*$/passwd:         files systemd winbind/' /etc/nsswitch.conf
sed -i 's/^group:.*$/group:          files systemd winbind/' /etc/nsswitch.conf

# ==============================================================================
# 7. BACKEND SMB1 MOUNT CONFIGURATION
# ==============================================================================
echo "[7/8] Configuring legacy SMB1 backend mount..."

# Create local proxy user
if ! id "${PROXY_FRONTEND_USER}" &>/dev/null; then
  useradd -M -s /usr/sbin/nologin "${PROXY_FRONTEND_USER}"
fi

mkdir -p "${PROXY_MOUNT}"
chown "${PROXY_FRONTEND_USER}:${PROXY_FRONTEND_USER}" "${PROXY_MOUNT}"

# Secure backend credentials
CREDS_FILE="/etc/samba/.ws2008_creds"
cat <<EOF > "${CREDS_FILE}"
username=${WS2008_USER}
password=${WS2008_PASS}
domain=${WS2008_DOMAIN}
EOF
chmod 600 "${CREDS_FILE}"

# Add to fstab
# Note: SMB1 is explicitly handled here by the cifs kernel module, which ignores 
# the 'client min protocol = SMB3' setting in smb.conf.
FSTAB_ENTRY="//${WS2008_IP}/${WS2008_SHARE} ${PROXY_MOUNT} cifs credentials=${CREDS_FILE},vers=1.0,cache=none,serverino,nobrl,uid=${PROXY_FRONTEND_USER},gid=${PROXY_FRONTEND_USER},_netdev,x-systemd.automount,x-systemd.requires=network-online.target 0 0"

if ! grep -q "${PROXY_MOUNT}" /etc/fstab; then
  echo "${FSTAB_ENTRY}" >> /etc/fstab
fi

# ==============================================================================
# 8. SERVICE RESTART & ACTIVATION
# ==============================================================================
echo "[8/8] Activating services and mounts..."
systemctl daemon-reload
systemctl restart remote-fs.target

# Ensure NetBIOS is completely disabled at the system service level
systemctl disable --now nmbd || true

systemctl restart winbind
systemctl restart smbd

echo ""
echo "=============================================================================="
echo "Setup Complete."
echo "1. Verify domain resolution by running: wbinfo -u"
echo "2. The backend share is mounted at: ${PROXY_MOUNT}"
echo "3. Windows 11 clients can access: \\\\<DEBIAN_DOMAIN_NIC_IP>\\${PROXY_SHARE_NAME}"
echo "=============================================================================="