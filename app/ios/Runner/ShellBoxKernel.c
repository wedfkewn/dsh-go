#include "ShellBoxKernel.h"
#include "ShellBoxBridge.h"

int dsh_shellbox_mount_root(const struct fs_ops *fs, const char *source) {
    return mount_root(fs, source);
}

int dsh_shellbox_become_first_process(void) {
    return become_first_process();
}

struct tty *dsh_shellbox_open_pty(struct tty_driver *driver) {
    return pty_open_fake(driver);
}
