# virtio-snd (out-of-tree)

The virtio sound driver (`sound/virtio`) from Linux v7.2.9, unmodified except
for the Makefile. The Arch Linux ARM kernel is built without
`CONFIG_SND_VIRTIO`, so ArchBox builds this as a DKMS module inside the guest.
DKMS rebuilds it after kernel updates.

Source: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/sound/virtio?h=v7.2.9

License: GPL-2.0-or-later, as stated in each file's SPDX header. This directory
is not covered by the MIT license of the rest of the repository.
