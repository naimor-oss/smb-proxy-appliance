# External Component Pins

`smbproxy-session-vfs.env` is the source/release contract for the custom Samba
VFS module. Image builds verify its component version, source hash, and exact
accepted Debian Samba revision against the sibling repository before staging
anything into the VM.

The component's tag workflow publishes a signed APT repository at the recorded
URI. After the repository exists and its signing-key fingerprint has been
verified out of band, install the key and the adjacent `.sources.example` as
part of the appliance release process. Do not enable the source with an
unverified key and do not weaken the package's exact Samba dependency.

Until that external setup is complete, image builds use the pinned, exported
source payload. The already-deployed `0.4.0-inplace7` updater remains a frozen
exception under `updates/`.
