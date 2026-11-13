#ifndef DSH_SHELLBOX_KERNEL_H
#define DSH_SHELLBOX_KERNEL_H
#include <stddef.h>
#include <stdbool.h>
struct guest_service;
/* All control calls are serialized by the plugin's kernel queue. Boot is
 * attempted once per Runner. No API tears down or boots a second kernel. */
typedef void (*dsh_shellbox_output)(const void *, size_t, int);
int dsh_shellbox_boot(const char *root);
int dsh_shellbox_launch(const char *command, const char *environment,
                        dsh_shellbox_output output, struct guest_service **out);
int dsh_shellbox_request_stop(struct guest_service *);
int dsh_shellbox_finish_stop(struct guest_service *);
/* Guest command result is set before the completion fence can succeed. */
int dsh_shellbox_command_status(void);
/* Last observed guest command PID; zero before a command is launched. */
int dsh_shellbox_command_pid(void);
#endif
