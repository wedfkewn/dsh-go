#ifndef DSH_SHELLBOX_KERNEL_H
#define DSH_SHELLBOX_KERNEL_H

/* Opaque upstream types keep ShellBox's internal headers out of Swift. */
struct fs_ops;
struct tty;
struct tty_driver;

/* These are individual primitives, NOT a boot/teardown lifecycle. The caller
 * must own the filesystem, driver and kernel thread context. Not yet called
 * by the channel: there is no prepared rootfs or lifecycle owner. */
int dsh_shellbox_mount_root(const struct fs_ops *fs, const char *source);
int dsh_shellbox_become_first_process(void);
/* Returns upstream ERR_PTR on failure, not NULL; caller must use IS_ERR. */
struct tty *dsh_shellbox_open_pty(struct tty_driver *driver);

#endif
