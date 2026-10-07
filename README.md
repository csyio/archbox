# ArchBox

A macOS app that runs Arch Linux ARM with KDE Plasma as a full-screen virtual machine on Apple Silicon. The first launch installs the system; every launch after that opens the desktop directly.

Built on Apple's Virtualization framework. There is no QEMU and no UTM.

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
   - installs systemd-boot
4. **Desktop.** Later launches boot the installed disk through `VZEFIBootLoader`. Kernel updates through `pacman -Syu` work as they do on any other Arch install.

Closing the window saves the VM state to disk. The next launch resumes from that point. If the saved state cannot be restored, the VM boots from scratch.

## Integration

| Feature | Status |
| --- | --- |
| Display resizes with the window | Yes (`automaticallyReconfiguresDisplay`) |
| Shared folder | `~/ArchShared` on the Mac is mounted at `~/Mac` in Arch |
| Clipboard | SPICE agent (`spice-vdagent`); limited under Wayland |
| Network | NAT |
| Disk | NVMe controller (see [Known issues](#known-issues)) |
| Audio | Not available. The Arch Linux ARM kernel is built without `virtio_snd`. |
| 3D acceleration | No. The display is virtio-gpu 2D and Plasma renders with llvmpipe. |

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

The script builds a release binary, puts together `build/ArchBox.app`, and signs it ad hoc with the `com.apple.security.virtualization` entitlement.

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
