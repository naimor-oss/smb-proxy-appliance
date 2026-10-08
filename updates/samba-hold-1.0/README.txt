SMB Proxy Samba package hold 1.0
================================

For an appliance installed before the image applied the hold itself.

The session module is built for one exact Samba version. Without a hold,
"Install updates" (apt full-upgrade) can upgrade Samba past that version, or
remove the module package to make room; either way the file service stops.

This bundle:

  * installs /usr/local/sbin/smbproxy-samba-hold;
  * holds every installed package built from Debian's samba source at its
    current version (apt-mark hold);
  * adds a login-banner line showing the held Samba version.

It does not change Samba, restart services, or touch shares or credentials.
Other Debian updates (kernel, OpenSSL, ...) still install normally.

Install
-------

  sha256sum -c smbproxy-samba-hold-1.0.tar.gz.sha256
  tar -xzf smbproxy-samba-hold-1.0.tar.gz
  cd smbproxy-samba-hold-1.0
  sudo ./install.sh

Check
-----

  sudo smbproxy-samba-hold status      # "... (held to match the session module)"
  apt-mark showhold

Samba is updated later only by a qualified update bundle, which installs the
new Samba together with a matching session module and re-applies the hold.
