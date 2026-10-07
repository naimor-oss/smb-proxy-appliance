SMB Proxy in-place updater 0.4.0-inplace7
=========================================

This one-off updater is for an already configured appliance built before:

  * modern/direct offline-share fail-fast behavior; and
  * one upstream SMB1 session per downstream authenticated tree; and
  * one normalized Samba lock/share-mode identity across those sessions.

It does not run prepare-image.sh and does not ask for backend passwords.
Existing /etc/samba credentials, domain settings, NIC roles, share state,
users, and access-group settings are preserved. Before changing generated
configuration it creates a root-only backup below:

  /var/backups/smbproxy-updater/<UTC timestamp>/

Requirements
------------

  * Run during a maintenance window; current SMB clients are disconnected.
  * Configured backends with an active mount must be reachable so their old
    mount can be cleanly unmounted. The updater refuses a lazy/forced unmount.
  * The appliance needs temporary access to its configured Debian repositories
    to download the matching Samba source/build dependencies and testsuite.
  * The updater installs the current candidate from the same Samba major/minor
    branch, including its testsuite. It refuses a branch change such as 4.22 to
    4.24. The configuration rollback does not downgrade Debian packages.
  * The installer refuses to proceed while any SMB clients remain connected.
    For an explicitly approved idle mapped drive that reconnects immediately,
    run with `sudo SMBPROXY_DRAIN_CLIENTS=1 ./install.sh`; the service's prior
    active state is preserved and restored.

Install
-------

Copy the tar file to the appliance, then:

  sha256sum -c smbproxy-inplace-updater-0.4.0-inplace7.tar.gz.sha256
  tar -xzf smbproxy-inplace-updater-0.4.0-inplace7.tar.gz
  cd smbproxy-inplace-updater-0.4.0-inplace7
  sudo ./install.sh

The installer prints the exact backup and rollback command when it finishes.

Basic appliance checks
----------------------

  sudo testparm -s
  sudo systemctl status smbd smbproxy-share-worker.timer
  sudo smbproxy-sconfig --status
  sudo findmnt -t cifs
  sudo tail -40 /var/log/smbproxy-session-mount.log

The hard SMB1 locking guarantee is not validated by installation alone. Run
the repository's live two-client release gate after updating:

  lab/run-scenario.sh tps-lock-isolation --verify-only
