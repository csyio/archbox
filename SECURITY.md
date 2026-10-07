# Security

ArchBox downloads an operating system, handles the account password you choose for it, and gives a virtual machine access to a folder on your Mac. Security reports are welcome.

Please report vulnerabilities privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue.

Useful details: the ArchBox version, the macOS version, the Mac model, and steps to reproduce.

Areas worth extra scrutiny:

- `Sources/ArchBox/SignatureVerifier.swift`: verifies the rootfs signature against the pinned key. Everything installed later trusts this check.
- `Sources/ArchBox/Installer.swift`: writes the account password into a short-lived initramfs segment and deletes it.
- `Resources/guest/archbox-provision`: runs as root in the installer VM and configures the installed system.
- `Sources/ArchBox/VMConfig.swift`: decides what the guest can reach on the Mac (shared folder, clipboard, Rosetta, microphone).
