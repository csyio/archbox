# SPDX-License-Identifier: GPL-2.0+
# Out-of-tree build of sound/virtio from Linux v7.2.9 (upstream sets
# obj-$(CONFIG_SND_VIRTIO); the Arch Linux ARM kernel has it disabled).

obj-m += virtio_snd.o

virtio_snd-y := \
	virtio_card.o \
	virtio_chmap.o \
	virtio_ctl_msg.o \
	virtio_jack.o \
	virtio_kctl.o \
	virtio_pcm.o \
	virtio_pcm_msg.o \
	virtio_pcm_ops.o
