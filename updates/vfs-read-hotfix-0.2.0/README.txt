SMB Proxy signed-SMB1 read hotfix 0.2.0
=======================================

This one-off updater replaces only the exact-Samba smbproxy-session-vfs
package. It does not run prepare-image.sh, use APT, alter share definitions,
or reboot. It backs up and verifies /etc/fstab, /etc/samba, /etc/smbproxy, and
/var/lib/smbproxy/shares. It supports both the older manually installed VFS
and the standalone Debian component package, preserving the matching rollback.

The installer refuses a Samba package mismatch or active SMB clients. After
users disconnect:

  sha256sum -c smbproxy-vfs-read-hotfix-0.2.0.tar.gz.sha256
  tar -xzf smbproxy-vfs-read-hotfix-0.2.0.tar.gz
  cd smbproxy-vfs-read-hotfix-0.2.0
  sudo ./install.sh

For an explicitly approved idle mapped drive that reconnects automatically:

  sudo SMBPROXY_DRAIN_CLIENTS=1 ./install.sh

Installation restarts smbd but does not reboot. The installer prints the
root-only backup directory and exact rollback command.

Acceptance requires all of the following after installation:

  * copy a file larger than 64 KiB through the downstream SMB3 share and
    verify its hash;
  * confirm no new "SMB signature verification returned error" messages;
  * run two application users and verify shared seat state and record locking.
