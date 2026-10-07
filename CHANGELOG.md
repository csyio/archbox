# Changelog

All notable changes to ArchBox are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-10-07

First release.

### Added

- First launch installs Arch Linux ARM with KDE Plasma into a 128 GB sparse disk image. Later launches boot it full screen through `VZEFIBootLoader`.
- Closing the window or quitting (⌘Q) saves the VM state. The next launch resumes from it, and falls back to a cold boot if the restore fails.
- The rootfs tarball's OpenPGP signature is checked in Swift against the pinned Arch Linux ARM Build System key. Signatures older than 2026-08-05 are rejected, and the archive must contain a rootfs.
- Sound output and microphone input. The guest builds the virtio sound driver with DKMS, because the Arch Linux ARM kernel leaves it out. A WirePlumber rule selects the Pro Audio profile, the only one that includes the microphone.
- Rosetta for x86_64 Linux programs, mounted at `/media/rosetta` and registered with binfmt_misc.
- Clipboard sharing (text, both directions) through `spice-vdagent` on XWayland, plus `archbox-clipboard-bridge` for Wayland apps. The bridge skips cleared clipboards and password-manager entries, and Klipper keeps no clipboard history on disk.
- The microphone is attached only after macOS grants access. A saved state is restored with the devices it was saved with.
- The installer uses several Arch Linux ARM mirrors without pacman's low-speed timeout, and retries a failed package download.
- Release zips carry a build provenance attestation; with Developer ID secrets set, releases are signed and notarized.
- Shared folder: `~/ArchShared` on the Mac appears as `~/Mac` in Arch.
- Turkish Q keyboard, the Mac's time zone, and a Retina scale on the first login.
- ⌃⌘F toggles full screen. ⌘Q saves and quits; every other ⌘ shortcut goes to Linux.

### Known issues

- No 3D acceleration. Virtualization.framework gives Linux guests a 2D virtio-gpu only, so Plasma renders with llvmpipe.
- Disks use NVMe because virtio-blk corrupted guest memory under sustained I/O in testing. See the README.
