# ArchBox

A macOS app that runs Arch Linux ARM with KDE Plasma as a full-screen virtual machine on Apple Silicon. The first launch installs the system; every launch after that opens the desktop directly.

Built on Apple's Virtualization framework. There is no QEMU and no UTM.

## Install

1. Download `ArchBox-<version>.zip` from [Releases](https://github.com/csyio/archbox/releases), unzip it and move `ArchBox.app` to `/Applications`.
2. Open it. If macOS says it cannot verify the app, that release is not notarized. Open **System Settings → Privacy & Security**, scroll down to the message about ArchBox, and click **Open Anyway**.
3. Choose a user name and password. The install takes 10–20 minutes, depending on your connection.
4. When macOS asks, allow microphone access if Linux apps should use the microphone.

Each release zip has a build provenance attestation. To check that a zip was built by this repository's release workflow, run `gh attestation verify ArchBox-<version>.zip --repo csyio/archbox`.

**What the VM can reach on your Mac:** the `~/ArchShared` folder, the clipboard (text), and, if you allowed it, the microphone, whenever the VM is running. Passwords you copy on the Mac are visible to Linux while it runs. ArchBox turns off Klipper's on-disk clipboard history. Its Wayland-to-X11 bridge skips cleared clipboards and password-manager entries, but KWin copies the clipboard to X11 on its own while an X11 app has focus, and `spice-vdagent` passes on whatever X11 holds. A password copied in Linux can therefore still reach the Mac. To remove microphone access later, use **System Settings → Privacy & Security → Microphone**.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- About 15 GB of free disk space (the 128 GB virtual disk is sparse and grows with use)
- An internet connection for the first install

## How it works

1. **Download.** The app downloads the official Arch Linux ARM `aarch64` rootfs tarball and its detached signature. It verifies the OpenPGP signature in Swift with `Security.framework`, against the Arch Linux ARM Build System key (`68B3537F39A313B3E574D06777193F152BDBE6A6`) that is built into the app. It does not trust a checksum from the mirror.
2. **Installer system.** `bsdtar` repacks the tarball into a cpio initramfs, leaving out firmware and documentation. It adds `archbox-provision` and a systemd unit that starts it. The account settings go into a separate segment (see [Files](#files)). Hard links, which bsdtar drops in this conversion, are added back as symlinks. The installer kernel is the `Image` taken from the same tarball.
3. **Install.** The installer boots straight into RAM through `VZLinuxBootLoader`. The tarball is attached as a second, read-only disk: an APFS clone padded to whole sectors, so it takes no extra space. [`Resources/guest/archbox-provision`](Resources/guest/archbox-provision) then runs and reports progress over the serial console (`@@STEP` and `@@STATUS` lines). The script:
   - partitions the virtual disk (GPT: 1 GiB EFI system partition and an ext4 root)
   - extracts the rootfs and updates it with `pacman`
   - installs KDE Plasma, SDDM, NetworkManager, PipeWire, Firefox and the base development tools
   - creates the user account, with sudo through the `wheel` group, and enables automatic login
   - builds the virtio sound driver with DKMS, and sets up Rosetta and clipboard sharing
   - installs systemd-boot
4. **Desktop.** Later launches boot the installed disk through `VZEFIBootLoader`. Kernel updates through `pacman -Syu` work as they do on any other Arch install.

Closing the window saves the VM state to disk. The next launch resumes from that point, with the same devices the state was saved with (microphone and Rosetta can change between launches). If the saved state cannot be restored, the VM boots from scratch with the devices available at that point.

## Integration

| Feature | Status |
| --- | --- |
| Display resizes with the window | Yes (`automaticallyReconfiguresDisplay`) |
| Shared folder | `~/ArchShared` on the Mac is mounted at `~/Mac` in Arch |
| Clipboard | Text, in both directions. See [Clipboard](#clipboard). |
| Sound | Speakers. The Arch Linux ARM kernel is built without `virtio_snd`, so the installer builds [the upstream driver](Resources/guest/virtio-snd) with DKMS. DKMS rebuilds it after kernel updates. |
| Microphone | Only after macOS grants ArchBox microphone access. Without access the guest gets no input device. PipeWire shows it as "Virtio 1.0 sound Pro 1" (a WirePlumber rule picks the Pro Audio profile, the only one with an input). |
| x86_64 programs | Through Rosetta, mounted at `/media/rosetta` and registered with binfmt_misc. This needs Rosetta on the Mac (`softwareupdate --install-rosetta`); ArchBox picks it up at the next cold start. |
| Network | NAT |
| Disk | NVMe controller (see [Known issues](#known-issues)) |
| 3D acceleration | No. Virtualization.framework gives Linux guests a 2D virtio-gpu only, so Plasma renders with llvmpipe. Code cannot change that. |

### Clipboard

Virtualization.framework shares the clipboard through a SPICE agent. `spice-vdagent` only understands X11, so ArchBox runs it against XWayland. KWin copies X11 text to Wayland apps on its own. The reverse only happens while an X11 window has focus. `archbox-clipboard-bridge` covers that direction: it watches the Wayland clipboard with `wl-paste --watch` and copies new text to X11 with `xclip`. Only text is shared, not images or files.

## Known issues

**virtio-blk corrupts guest memory under sustained disk I/O.** Seen on a MacBook Air M5 with macOS 27.0.1 and the Arch Linux ARM 7.1.6 kernel. In about half of the runs, the guest kernel crashed within a minute of heavy disk writes. Crashes included NULL seccomp BPF programs, `Bad rss-counter state`, refcount underflows and oopses. Controlled runs of the installer's stress modes:

| Load | Disk bus | Crashed |
| --- | --- | --- |
| Extract rootfs to disk + hash 3 GB, 3 rounds | virtio-blk | 4 of 8 |
| Same | NVMe | 0 of 6 |
| Same work in RAM only | virtio-blk attached, idle | 0 of 3 |
| 800 MB of parallel downloads | virtio-blk attached, idle | 0 of 2 |

The crash rate did not change with 1 CPU, with 4 GB of RAM, with SME turned off (`arm64.nosme`), or with virtiofs removed. ArchBox therefore attaches disks through `VZNVMExpressControllerDeviceConfiguration`. `ARCHBOX_DISK_BUS=virtio` brings virtio-blk back for testing.

## Building

```sh
./scripts/build-app.sh
open build/ArchBox.app
```

The script builds a release binary, puts together `build/ArchBox.app`, and signs it ad hoc with the entitlements in `Resources/ArchBox.entitlements`. With `SIGN_IDENTITY` set to a Developer ID, it signs for distribution instead.

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the app and publishes a GitHub release with `ArchBox-<version>.zip`. If the repository has the secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`, the release is signed with a Developer ID and notarized, and the workflow fails if the certificate holds no Developer ID identity. Without the secrets it is signed ad hoc.

## Files

The app keeps all of its data in `~/Library/Application Support/ArchBox`:

| File | Purpose |
| --- | --- |
| `disk.img` | Virtual disk (sparse) |
| `efi-variables.fd` | UEFI variable store |
| `saved-state.vzvmsave` | Suspended VM state; removed after a resume |
| `console.log` | Guest serial console (`hvc0`) from the last boot |
| `install/console.log` | Installer serial console, including the provisioning log |
| `cache/` | Downloaded rootfs tarball (excluded from backups) |

The account password is kept out of the large initramfs. When the installer starts, the app writes an owner-only `config.env`, packs it into a small cpio segment and appends that segment to a clone of the secret-free initramfs. `config.env` is then deleted right away, and the combined initramfs is deleted once the installer VM has started. Both are also deleted at every launch, in case an earlier install was killed. Two risks remain. A local APFS (Time Machine) snapshot taken in those few seconds keeps a copy. Deleted blocks are not overwritten, so turn on FileVault.

To reinstall, quit the app and delete `disk.img` and `installed`.

## Testing

`ArchBox --unattended-install` skips the account form. It reads the account from the `ARCHBOX_USER`, `ARCHBOX_FULLNAME` and `ARCHBOX_PASSWORD` environment variables. Other environment variables, for development only:

| Variable | Effect |
| --- | --- |
| `ARCHBOX_TEST=local\|ram\|network` | The installer runs a stress test instead of installing |
| `ARCHBOX_DISK_BUS=nvme\|virtio` | Disk controller (default `nvme`) |
| `ARCHBOX_CPUS`, `ARCHBOX_MEMORY_GB` | Override the CPU count and the memory size |
| `ARCHBOX_DEV_SSH_KEY` | A public key. The installer enables sshd and authorizes the key for the user, so tests can reach the guest. |

## License

MIT, see [LICENSE](LICENSE). The exception is `Resources/guest/virtio-snd`, which is the Linux virtio sound driver under GPL-2.0-or-later.
