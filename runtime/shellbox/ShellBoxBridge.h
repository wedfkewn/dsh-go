#ifndef DSH_GO_SHELLBOX_BRIDGE_H
#define DSH_GO_SHELLBOX_BRIDGE_H

/* Upstream declarations, not a stable embedding wrapper.
 * Add the pinned ShellBox source root to header search paths.
 * kernel/init.h: mount_root, become_first_process and stdio helpers.
 * fs/tty.h: struct tty *pty_open_fake(struct tty_driver *driver).
 * Not compiled or linked yet; no runtime initialization is performed here.
 */
#include "kernel/init.h"
#include "fs/tty.h"

#endif
