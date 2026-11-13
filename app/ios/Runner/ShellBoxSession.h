#ifndef DSH_SHELLBOX_SESSION_H
#define DSH_SHELLBOX_SESSION_H
#include <stdbool.h>
/* Control state lives on the platform thread; worker completion returns there.
 * StopBlocked retains the same service handle until a successful fence. */
enum sb_phase { SB_IDLE, SB_STARTING, SB_RUNNING, SB_STOPPING, SB_STOP_BLOCKED,
                SB_STOPPED, SB_RESETTING, SB_ERROR, SB_INSTALLED };
static inline const char *sb_phase_name(enum sb_phase phase) {
    switch (phase) {
        case SB_IDLE: return "";
        case SB_STARTING: return "starting";
        case SB_RUNNING: return "running";
        case SB_STOPPING: return "stopping";
        case SB_STOP_BLOCKED: return "stopBlocked";
        case SB_STOPPED: return "stopped";
        case SB_RESETTING: return "resetting";
        case SB_ERROR: return "error";
        case SB_INSTALLED: return "installed";
    }
    return "error";
}
static inline bool sb_can_initialize(enum sb_phase phase, bool pending) {
    return !pending && (phase == SB_IDLE || phase == SB_INSTALLED ||
                         phase == SB_STOPPED || phase == SB_ERROR);
}
static inline bool sb_can_stop(enum sb_phase phase, bool pending) {
    return !pending && (phase == SB_STARTING || phase == SB_RUNNING || phase == SB_STOP_BLOCKED);
}
static inline enum sb_phase sb_stop_result(bool complete) {
    return complete ? SB_STOPPED : SB_STOP_BLOCKED;
}
/* Fixed guest paths only. Default find -P keeps links opaque; the fakefs
 * syscalls own unlink/rmdir metadata updates. Never host-delete active/data. */
#define SB_RESET_BASE "/usr/bin/find /root -xdev -depth ! -path /root"
#define SB_KEEP_UI " ! -path '/root/.dsh/dsh-go' ! -path '/root/.dsh/dsh-go/*'" \
    " ! -path '/root/.dsh/skills' ! -path '/root/.dsh/skills/*'" \
    " ! -path '/root/.agents/skills' ! -path '/root/.agents/skills/*'" \
    " ! -path '/root/.dsh' ! -path '/root/.agents'"
#define SB_KEEP_PLUGINS " ! -path '/root/.dsh/profiles' ! -path '/root/.dsh/profiles/*'" \
    " ! -path '/root/.dsh/cordis.patch.yml' ! -path '/root/.dsh/.env' ! -path '/root/.dsh'"
static inline const char *sb_reset_command(bool ui, bool plugins) {
    if (ui) return plugins ? SB_RESET_BASE SB_KEEP_UI SB_KEEP_PLUGINS " -delete" :
                            SB_RESET_BASE SB_KEEP_UI " -delete";
    return plugins ? SB_RESET_BASE SB_KEEP_PLUGINS " -delete" : SB_RESET_BASE " -delete";
}
#undef SB_RESET_BASE
#undef SB_KEEP_UI
#undef SB_KEEP_PLUGINS
#endif
