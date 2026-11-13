#!/usr/bin/env python3
"""Linux component probes, not a guest or Darwin lifecycle acceptance test."""
from pathlib import Path
import subprocess
import sys
import tempfile

upstream = Path(sys.argv[1])
patch = Path(__file__).resolve().parents[1] / 'embedded-lifecycle.patch'

def function(source, name, end):
    return source[source.index(name):source.index(end, source.index(name))]

with tempfile.TemporaryDirectory(prefix='shellbox-lifecycle-') as directory:
    root = Path(directory)
    pin = '5dfc962fe5e03fe5bc6b869b8744312ebe6af627'
    tracked = subprocess.check_output(['git', '-C', str(upstream), 'ls-tree', '-r',
                                       '--name-only', pin], text=True).splitlines()
    patches = [patch.parent / name for name in (
        'fix-duplicate-gadgets.patch', 'fix-node24-v8-flags.patch',
        'fix-fakefs-import-cleanup.patch', 'embedded-lifecycle.patch',
        'remove-unshipped-preload.patch')]
    changed = {line[6:] for item in patches for line in item.read_text().splitlines()
               if line.startswith('+++ b/')}
    inputs = [name for name in tracked if name in changed or name in ('fs/mount.c', 'fs/fake.c') or name.endswith('.h')]
    # Only patched inputs and headers, not the large generated offload corpus.
    subprocess.run(['git', '-C', str(upstream), 'archive', pin, '-o',
                    str(root / 'source.tar'), '--', *inputs], check=True)
    subprocess.run(['tar', '-xf', str(root / 'source.tar'), '-C', str(root)], check=True)
    for item in patches:
        for args in [['--check'], [], ['--reverse', '--check']]:
            subprocess.run(['git', 'apply', *args, str(item)], cwd=root, check=True)
    # Exercise the already-patched rebuild path in build-ios-libs.sh order.
    for item in patches:
        subprocess.run(['git', 'apply', '--reverse', '--check', str(item)], cwd=root, check=True)
    print('PASS all five patches check/apply/reverse-check and rebuild checks', flush=True)
    for name in ('kernel/exec.c', 'xX_main_Xx.h'):
        assert 'LD_PRELOAD=/lib/zero_free.so' not in (root / name).read_text()
    print('PASS session8-no-unshipped-preload-in-either-entrypoint (source check, not guest stderr)', flush=True)


    def probe(name, source, extra=()):
        if "--round6-only" in sys.argv[2:] and not (
                name.startswith("service6-") or name.startswith("trial-service6-")):
            return
        c = root / (name + '.c')
        c.write_text(source)
        binary = root / name
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-pthread',
                        '-DGUEST_ARM64=1', '-I' + str(root), str(c),
                        *[str(root / item) for item in extra], '-o', str(binary)], check=True)
        subprocess.run([str(binary)], timeout=10, check=True)
        label = 'CONFIRMED LIMITATION ' if name == 'blocked-realfs-read-stop-gap' or name.startswith('trial-') else 'PASS '
        print(label + name, flush=True)

    real = (root / 'fs/real.c').read_text()
    io = function(real, 'ssize_t realfs_read(', '\nvoid realfs_opendir')
    probe('realfs-stop-before-eintr-retry', r'''
#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <sys/types.h>
#include <stdbool.h>
struct fd { int real_fd; char *change_path; };
#define _EINTR (-EINTR)
#define FAKEFS_CHANGE_OP_WRITE 1
static int calls, changes;
static bool stop;
static bool guest_threads_stopping(void) { return stop; }
static int errno_map(void) { return -errno; }
static void fakefs_record_change(const char *path, int op) {
    (void)path; (void)op; changes++;
}
static ssize_t injected(int fd, const void *buf, size_t size, ...) {
    (void)fd; (void)buf; (void)size;
    calls++; stop = true; errno = EINTR; return -1;
}
#define read injected
#define write injected
#define pread injected
#define pwrite injected
''' + io + r'''
int main(void) {
    struct fd fd = {0, "changed"}; char byte;
    for (int op = 0; op < 4; op++) {
        calls = changes = 0; stop = false;
        ssize_t result = op == 0 ? realfs_read(&fd, &byte, 1) :
            op == 1 ? realfs_write(&fd, &byte, 1) :
            op == 2 ? realfs_pread(&fd, &byte, 1, 0) : realfs_pwrite(&fd, &byte, 1, 0);
        assert(result == -EINTR && calls == 1 && changes == 0);
    }
    assert(realfs_read(&fd, &byte, 1) == -EINTR && calls == 1);
}
''')
    destroy = function((root / 'kernel/task.c').read_text(), 'void task_destroy(', '\nstatic void task_run_tlb_cleanup')
    probe('registry-retirement-and-stop', r'''
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
struct task { int pid, value, siblings; };
struct pid { struct task *task; };
static struct pid slot;
static struct pid *pid_get(int id) { assert(id == 1); return &slot; }
static void syscall_refs_free(struct task *task) { (void)task; }
static void list_remove(int *entry) { *entry = 0; }
''' + destroy + r'''
static int gate[2], entered[2];
static void *worker(void *arg) {
    struct task *storage = arg; char byte;
    assert(write(entered[1], "!", 1) == 1);
    assert(read(gate[0], &byte, 1) == 1);
    assert(storage->value == 42); /* task storage survives retirement while alive */
    pthread_exit(NULL); /* exercises completion cleanup, not just return */
}
int main(void) {
    assert(pipe(gate) == 0 && pipe(entered) == 0);
    struct task *storage = malloc(sizeof(*storage));
    *storage = (struct task){.pid = 1, .value = 42, .siblings = 1}; slot.task = storage;
    pthread_t thread; char byte;
    assert(guest_thread_create(&thread, worker, storage, storage) == 0);
    assert(read(entered[0], &byte, 1) == 1);
    task_destroy(storage);
    assert(slot.task == NULL && storage->siblings == 0);
    assert(guest_threads_reap() == 0); /* must not join/free the blocked worker */
    guest_threads_request_stop();
    assert(guest_threads_join_stopped() == EBUSY);
    assert(guest_thread_create(&thread, worker, NULL, NULL) == ECANCELED);
    assert(write(gate[1], "!", 1) == 1);
    /* The registry owns join; wait for its completion publication. */
    int result;
    do { result = guest_threads_join_stopped(); if (result == EBUSY) usleep(1000); }
    while (result == EBUSY);
    assert(result == 0 && guest_threads_join_stopped() == 0);
    close(gate[0]); close(gate[1]); close(entered[0]); close(entered[1]);
}
''', ['util/guest_threads.c'])

    timer = (root / 'util/timer.c').read_text()
    probe('timer-wake-free-join-without-signals', r'''
#include "util/timer.h"
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
#include <unistd.h>
static pthread_mutex_t observed_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t observed = PTHREAD_COND_INITIALIZER;
static int waiting;
int errno_map(void) { return -errno; }
static int observed_wait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                         const struct timespec *deadline) {
    pthread_mutex_lock(&observed_lock); waiting = 1;
    pthread_cond_signal(&observed); pthread_mutex_unlock(&observed_lock);
    return pthread_cond_timedwait(cond, mutex, deadline);
}
#define pthread_cond_timedwait observed_wait
''' + timer + r'''
static void callback(void *arg) { (void)arg; assert(!"cancelled timer fired"); }
int main(void) {
    struct timer *timer = timer_new(CLOCK_MONOTONIC, callback, NULL);
    assert(timer != NULL);
    struct timer_spec spec = {.value = {100, 0}};
    assert(timer_set(timer, spec, NULL) == 0);
    pthread_mutex_lock(&observed_lock);
    while (!waiting) pthread_cond_wait(&observed, &observed_lock);
    pthread_mutex_unlock(&observed_lock);
    timer_free(timer);
    guest_threads_request_stop();
    int result;
    do { result = guest_threads_join_stopped(); if (result == EBUSY) usleep(1000); }
    while (result == EBUSY);
    assert(result == 0);
    timer = timer_new(CLOCK_MONOTONIC, callback, NULL);
    assert(timer_set(timer, spec, NULL) == -EINTR);
    assert(!timer->active && !timer->thread_running);
    timer_free(timer);
}
''', ['util/guest_threads.c'])

    first_exec = (root / 'kernel/init.c').read_text().split('_Noreturn void run_first_process(')[1]
    probe('first-exec-error-dispatch', r'''
#include <assert.h>
#include <stddef.h>
#include <setjmp.h>
static jmp_buf done;
static int injected_error, reported, exited, ran;
static int do_execve(const char *file, size_t argc, const char *argv, const char *envp) {
    (void)file; (void)argc; (void)argv; (void)envp; return injected_error;
}
static void report(int error) { assert(error == injected_error); reported++; }
_Noreturn static void do_exit(int status) {
    assert(reported == 1 && status == (127 << 8)); exited++; longjmp(done, 1);
}
_Noreturn static void task_run_current(void) { ran++; longjmp(done, 1); }
_Noreturn void run_first_process(''' + first_exec + r'''
int main(void) {
    int errors[] = {-2, -13, -8, -12};
    for (size_t n = 0; n < sizeof(errors)/sizeof(errors[0]); n++) {
        injected_error = errors[n]; reported = exited = ran = 0;
        if (setjmp(done) == 0) run_first_process("init", 0, "", "", report);
        assert(reported == 1 && exited == 1 && ran == 0);
    }
    injected_error = 0; reported = exited = ran = 0;
    if (setjmp(done) == 0) run_first_process("init", 0, "", "", report);
    assert(reported == 0 && exited == 0 && ran == 1);
}
''')

    read_body = function(real, 'ssize_t realfs_read(', '\nssize_t realfs_write(')
    probe('blocked-realfs-read-stop-gap', r'''
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <unistd.h>
#include <stdio.h>
struct fd { int real_fd; };
#define _EINTR (-EINTR)
static int entered[2], finished[2], input[2];
static int errno_map(void) { return -errno; }
static ssize_t observed_read(int fd, void *buf, size_t size) {
    assert(write(entered[1], "!", 1) == 1);
    return read(fd, buf, size);
}
#define read observed_read
''' + read_body + r'''
#undef read
static void *blocked(void *arg) {
    (void)arg; struct fd fd = {input[0]}; char byte;
    assert(realfs_read(&fd, &byte, 1) == 1);
    assert(write(finished[1], "!", 1) == 1);
    return NULL;
}
int main(void) {
    assert(pipe(entered) == 0 && pipe(finished) == 0 && pipe(input) == 0);
    pthread_t thread; char byte;
    assert(guest_thread_create(&thread, blocked, NULL, NULL) == 0);
    assert(read(entered[0], &byte, 1) == 1);
    guest_threads_request_stop();
    struct pollfd completion = {.fd = finished[0], .events = POLLIN};
    assert(poll(&completion, 1, 50) == 0);
    assert(guest_threads_join_stopped() == EBUSY);
    /* Release the real blocking read ourselves, not by the stop API. */
    assert(write(input[1], "!", 1) == 1);
    assert(read(finished[0], &byte, 1) == 1);
    int result;
    do { result = guest_threads_join_stopped(); if (result == EBUSY) usleep(1000); }
    while (result == EBUSY);
    assert(result == 0);
    puts("EXPECTED LIMITATION: stop does not wake an already blocked realfs read");
}
''', ['util/guest_threads.c'])

    exit_source = (root / 'kernel/exit.c').read_text()
    init_branch = function(exit_source,
        '        if (parent == NULL && leader->pid == 1 && embedded_init_exit_notify != NULL)',
        '        } else if (parent == NULL)') + '        }\n'
    notify_tail = function(exit_source, '    unlock(&pids_lock);\n\n    if (embedded_init_exit)',
                           '\n}\n')
    probe('init-exit-unlocked-notification', r'''
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <unistd.h>
static pthread_mutex_t pids_lock = PTHREAD_MUTEX_INITIALIZER;
#define unlock pthread_mutex_unlock
struct task { int pid; bool zombie; };
static struct task init = {.pid = 1};
static int notified;
static void notify_exit(int status) {
    assert(status == 37 && init.zombie);
    assert(pthread_mutex_trylock(&pids_lock) == 0);
    pthread_mutex_unlock(&pids_lock);
    notified++;
}
static void (*embedded_init_exit_notify)(int) = notify_exit;
static void *exit_worker(void *arg) {
    (void)arg;
    struct task *parent = NULL, *leader = &init;
    bool embedded_init_exit = false;
    int status = 37;
    pthread_mutex_lock(&pids_lock);
''' + init_branch + notify_tail + r'''
    return NULL;
}
int main(void) {
    pthread_t thread;
    assert(guest_thread_create(&thread, exit_worker, NULL, NULL) == 0);
    guest_threads_request_stop();
    int result;
    do { result = guest_threads_join_stopped(); if (result == EBUSY) usleep(1000); }
    while (result == EBUSY);
    assert(result == 0 && notified == 1);
}
''', ['util/guest_threads.c'])

    start_body = function((root / 'kernel/task.c').read_text(), 'int task_start(',
                          '\nint_t sys_sched_yield(')
    probe('task-start-stop-admission-error', r'''
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
struct task { pthread_t thread; };
static void *task_thread(void *arg) { (void)arg; assert(0); return NULL; }
''' + start_body + r'''
int main(void) {
    struct task task;
    guest_threads_request_stop();
    assert(task_start(&task) == ECANCELED);
    assert(guest_threads_join_stopped() == 0);
}
''', ['util/guest_threads.c'])

    discard = function((root / 'kernel/fork.c').read_text(),
                       'static void discard_unstarted_task(', '\ndword_t sys_clone(')
    probe('clone-unstarted-resource-rollback', r'''
#include <assert.h>
#include <stddef.h>
typedef unsigned dword_t;
#define CLONE_THREAD_ 1
struct group { int lock; };
struct task { struct group *group; int group_links; void *sighand, *fs, *files, *mm; };
static int pids_lock, released, groups, destroyed;
static void lock(int *value) { assert(!*value); *value = 1; }
static void unlock(int *value) { assert(*value); *value = 0; }
static void list_remove(int *value) { assert(pids_lock && *value); *value = 0; }
static void tgroup_free(struct group *group) {
    assert(pids_lock && !group->lock); groups++;
}
static void release(void *value) { assert(!pids_lock && value != NULL); released++; }
#define sighand_release release
#define fs_info_release release
#define fdtable_release release
#define mm_release release
static void task_destroy(struct task *task) {
    assert(pids_lock && task->group == NULL && !task->group_links && released == 4);
    destroyed++;
}
''' + discard + r'''
int main(void) {
    for (unsigned flags = 0; flags <= CLONE_THREAD_; flags++) {
        struct group group = {0}; int resource;
        struct task task = {&group, 1, &resource, &resource, &resource, &resource};
        released = groups = destroyed = 0;
        discard_unstarted_task(&task, flags);
        assert(released == 4 && destroyed == 1 && !pids_lock && !group.lock);
        assert(groups == !(flags & CLONE_THREAD_));
    }
}
''')

    # Round 4: use the real list macros and the patched parent selection/move.
    parent_lookup = function(exit_source, 'static struct task *find_new_parent(',
                             '\nnoreturn void do_exit(')
    reparent = function(exit_source, '    struct task *new_parent = find_new_parent(current);',
                        '\n    bool auto_reap')
    probe('embedded-init-zombie-child-ownership', r'''
#include <assert.h>
#include "misc.h"
#include "util/list.h"
struct group { struct list threads; };
struct task {
    int pid; bool exiting, zombie; struct group *group;
    struct task *parent;
    struct list group_links, children, siblings;
};
static struct task init;
static void (*embedded_init_exit_notify)(int);
static void notification(int status) { (void)status; }
static struct task *pid_get_task(int pid) {
    assert(pid == 1); return init.zombie ? NULL : &init;
}
static struct task *pid_get_task_zombie(int pid) { assert(pid == 1); return &init; }
''' + parent_lookup + r'''
static void move_children(struct task *current) {
''' + reparent + r'''
}
int main(void) {
    struct group groups[2]; struct task child = {0}, grandchildren[2] = {{0}, {0}};
    list_init(&groups[0].threads); list_init(&groups[1].threads);
    init.pid = 1; init.group = &groups[0]; init.exiting = true;
    list_init(&init.children); list_init(&child.children);
    list_add(&groups[0].threads, &init.group_links);
    child.group = &groups[1]; child.exiting = true;
    list_add(&groups[1].threads, &child.group_links);
    embedded_init_exit_notify = notification;
    /* PID 1 exits with two children. Moving onto its own list can loop. */
    for (int n = 0; n < 2; n++) {
        grandchildren[n].parent = &init;
        list_add(&init.children, &grandchildren[n].siblings);
    }
    move_children(&init);
    assert(list_size(&init.children) == 2);
    /* After zombie marking, pid_get_task hides init; drain still needs it. */
    init.zombie = true;
    assert(pid_get_task(1) == NULL && find_new_parent(&child) == &init);
    list_remove(&grandchildren[0].siblings);
    grandchildren[0].parent = &child;
    list_add(&child.children, &grandchildren[0].siblings);
    move_children(&child);
    assert(list_empty(&child.children) && list_size(&init.children) == 2);
    assert(grandchildren[0].parent == &init);
    embedded_init_exit_notify = NULL;
    assert(find_new_parent(&child) == NULL); /* CLI lookup contract retained */
}
''')

    # An implementation trial, deliberately NOT shipped: one pthread_kill per
    # worker after setting stop. Pause immediately after the retry guard, so the
    # signal is handled before entering read/accept/connect. No timing lottery.
    probe('trial-single-signal-loses-pre-syscall-wakeup', r'''
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>
static sem_t past_guard, enter_call, signal_seen;
static atomic_bool stopping;
static int mode, input[2], completed_pipe[2];
static void handler(int sig) { (void)sig; sem_post(&signal_seen); }
static void sem_wait_retry(sem_t *sem) {
    int err;
    do { err = sem_wait(sem); } while (err < 0 && errno == EINTR);
    assert(err == 0);
}
/* Deterministic host-call shim: all three calls block on an empty host pipe.
 * The sandbox denies bind(2) with EPERM, so no real socket claim is made. */
static int host_wait_shim(void) {
    char byte; return read(input[0], &byte, 1);
}
static void *trial(void *arg) {
    (void)arg;
    if (atomic_load(&stopping)) return NULL;
    assert(sem_post(&past_guard) == 0);
    sem_wait_retry(&enter_call);
    assert(host_wait_shim() == 1);
    assert(write(completed_pipe[1], "!", 1) == 1);
    return NULL;
}
int main(void) {
    struct sigaction action = {.sa_handler = handler};
    sigemptyset(&action.sa_mask); assert(sigaction(SIGUSR1, &action, NULL) == 0);
    assert(sem_init(&past_guard, 0, 0) == 0 && sem_init(&enter_call, 0, 0) == 0);
    assert(sem_init(&signal_seen, 0, 0) == 0);
    assert(pipe(input) == 0 && pipe(completed_pipe) == 0);
    for (mode = 0; mode < 3; mode++) {
        atomic_store(&stopping, false);
        pthread_t worker; assert(pthread_create(&worker, NULL, trial, NULL) == 0);
        sem_wait_retry(&past_guard);
        atomic_store(&stopping, true);
        assert(pthread_kill(worker, SIGUSR1) == 0);
        sem_wait_retry(&signal_seen);
        assert(sem_post(&enter_call) == 0);
        struct pollfd completion = {.fd = completed_pipe[0], .events = POLLIN};
        assert(poll(&completion, 1, 50) == 0);
        /* External release, NOT a successful stop. */
        assert(write(input[1], "!", 1) == 1);
        assert(poll(&completion, 1, 1000) == 1);
        char byte; assert(read(completed_pipe[0], &byte, 1) == 1);
        assert(pthread_join(worker, NULL) == 0);
    }
    puts("TRIAL REJECTED: one stop signal loses pre-host-call wakeup (pipe shim)");
}
''')

    probe('trial-pthread-cancel-skips-resource-unwind', r'''
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
static pthread_mutex_t resource_lock = PTHREAD_MUTEX_INITIALIZER;
static int input[2], entered[2];
static void *trial(void *arg) {
    (void)arg; char byte;
    assert(pthread_mutex_lock(&resource_lock) == 0);
    assert(write(entered[1], "!", 1) == 1);
    (void)read(input[0], &byte, 1);
    assert(pthread_mutex_unlock(&resource_lock) == 0);
    return NULL;
}
int main(void) {
    assert(pipe(input) == 0 && pipe(entered) == 0);
    pthread_t thread; void *result; char byte;
    assert(pthread_create(&thread, NULL, trial, NULL) == 0);
    assert(read(entered[0], &byte, 1) == 1);
    assert(pthread_cancel(thread) == 0 && pthread_join(thread, &result) == 0);
    assert(result == PTHREAD_CANCELED);
    assert(pthread_mutex_trylock(&resource_lock) == EBUSY);
    puts("TRIAL REJECTED: cancellation joins worker but leaves its caller's mutex owned");
}
''')

    probe('trial-poll-wake-descriptor-readiness-race', r'''
#include <assert.h>
#include <poll.h>
#include <pthread.h>
#include <semaphore.h>
#include <errno.h>
#include <unistd.h>
#include <stdio.h>
static int input[2], wake[2], finished[2];
static sem_t ready, proceed;
static void wait_sem(sem_t *sem) {
    int result;
    do { result = sem_wait(sem); } while (result < 0 && errno == EINTR);
    assert(result == 0);
}
/* Rejected implementation trial: putting a stop fd in poll while leaving
 * the following host read blocking. A competing reader can consume readiness. */
static void *trial(void *arg) {
    (void)arg;
    struct pollfd descriptors[] = {{input[0], POLLIN, 0}, {wake[0], POLLIN, 0}};
    assert(poll(descriptors, 2, -1) == 1);
    assert(descriptors[0].revents & POLLIN);
    assert(sem_post(&ready) == 0);
    wait_sem(&proceed);
    char byte;
    assert(read(input[0], &byte, 1) == 1);
    assert(write(finished[1], "!", 1) == 1);
    return NULL;
}
int main(void) {
    assert(pipe(input) == 0 && pipe(wake) == 0 && pipe(finished) == 0);
    assert(sem_init(&ready, 0, 0) == 0 && sem_init(&proceed, 0, 0) == 0);
    assert(write(input[1], "!", 1) == 1);
    pthread_t thread; assert(pthread_create(&thread, NULL, trial, NULL) == 0);
    wait_sem(&ready);
    char byte; assert(read(input[0], &byte, 1) == 1); /* second reader */
    assert(write(wake[1], "!", 1) == 1); /* stop */
    assert(sem_post(&proceed) == 0);
    struct pollfd completion = {finished[0], POLLIN, 0};
    assert(poll(&completion, 1, 50) == 0);
    assert(write(input[1], "!", 1) == 1); /* external release */
    assert(poll(&completion, 1, 1000) == 1);
    assert(pthread_join(thread, NULL) == 0);
    puts("TRIAL REJECTED: wake fd in poll cannot interrupt the subsequent blocking read");
}
''')

    mount_remove = function((root / 'fs/mount.c').read_text(),
                            'static int mount_remove_locked(', '\nint mount_remove(')
    probe('busy-mount-preserved-until-reference-drain', r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "misc.h"
#include "util/list.h"
#define _EBUSY (-16)
struct mount;
struct fs_ops { void (*umount)(struct mount *); };
struct mount {
    int refcount; struct list mounts; const struct fs_ops *fs;
    const char *info, *source, *point;
};
static int mounts_lock, unmounted;
static struct list mounts;
static void unlock(int *lock) { assert(*lock == 1); *lock = 0; }
static void umount_callback(struct mount *mount) {
    assert(!mounts_lock && mount->refcount == 0 && list_empty(&mounts));
    unmounted++;
}
''' + mount_remove + r'''
int main(void) {
    struct fs_ops fs = {.umount = umount_callback};
    struct mount *mount = calloc(1, sizeof(*mount)); assert(mount);
    mount->fs = &fs; mount->info = strdup(""); mount->source = strdup("root");
    mount->point = strdup(""); mount->refcount = 2; /* pwd + root */
    list_init(&mounts); list_add(&mounts, &mount->mounts);
    mounts_lock = 1; assert(mount_remove_locked(mount) == _EBUSY);
    assert(!mounts_lock && !unmounted && list_size(&mounts) == 1);
    mount->refcount--; /* one reference release is insufficient */
    mounts_lock = 1; assert(mount_remove_locked(mount) == _EBUSY);
    assert(!mounts_lock && !unmounted && list_size(&mounts) == 1);
    mount->refcount--; /* all owners released before removal */
    mounts_lock = 1; assert(mount_remove_locked(mount) == 0);
    assert(!mounts_lock && unmounted == 1 && list_empty(&mounts));
}
''')

    init_source = (root / 'kernel/init.c').read_text()
    establish = function(init_source, 'struct boot_signal_handlers {',
                         '\n// copied from')
    become = function(init_source, 'int become_first_process(',
                      '\nint become_new_init_child(')
    probe('construction-failure-restores-host-signal-dispositions', r'''
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
struct task { int unused; };
static struct task *current;
static int errno_map(void) { return -errno; }
#define IS_ERR(p) ((intptr_t)(p) < 0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
static struct task *construct_task(struct task *parent) {
    assert(parent == NULL); return (void *)(intptr_t)-ENOMEM;
}
void sigusr1_handler(int sig) { (void)sig; }
static void host_handler(int sig) { (void)sig; }
''' + establish + become + r'''
int main(void) {
    struct sigaction original_usr, original_pipe, action = {.sa_handler = host_handler}, actual;
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGUSR1, &action, &original_usr) == 0);
    assert(sigaction(SIGPIPE, &action, &original_pipe) == 0);
    assert(become_first_process() == -ENOMEM && current == NULL);
    assert(sigaction(SIGUSR1, NULL, &actual) == 0 && actual.sa_handler == host_handler);
    assert(sigaction(SIGPIPE, NULL, &actual) == 0 && actual.sa_handler == host_handler);
    /* Restore the original test-process dispositions too. */
    assert(sigaction(SIGUSR1, &original_usr, NULL) == 0);
    assert(sigaction(SIGPIPE, &original_pipe, NULL) == 0);
    puts("RESTORED: failed construction restores both host dispositions");
}
''')

    probe('boot-signal-install-and-restore-errors', r'''
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stddef.h>
struct task { int unused; };
static struct task *current;
static int calls, fail_call, constructed;
static int errno_map(void) { return -errno; }
#define IS_ERR(p) ((intptr_t)(p) < 0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
static struct task *construct_task(struct task *parent) {
    assert(parent == NULL); constructed++; return (void *)(intptr_t)-ENOMEM;
}
void sigusr1_handler(int sig) { (void)sig; }
static void host_handler(int sig) { (void)sig; }
static int injected_sigaction(int sig, const struct sigaction *action, struct sigaction *old) {
    if (++calls == fail_call) { errno = EIO; return -1; }
    return sigaction(sig, action, old);
}
#define sigaction(...) injected_sigaction(__VA_ARGS__)
''' + establish + become + r'''
#undef sigaction
int main(void) {
    struct sigaction host = {.sa_handler = host_handler}, original_usr, original_pipe, actual;
    sigemptyset(&host.sa_mask);
    assert(sigaction(SIGUSR1, &host, &original_usr) == 0);
    assert(sigaction(SIGPIPE, &host, &original_pipe) == 0);
    for (fail_call = 1; fail_call <= 4; fail_call++) {
        assert(sigaction(SIGUSR1, &host, NULL) == 0);
        assert(sigaction(SIGPIPE, &host, NULL) == 0);
        calls = constructed = 0;
        assert(become_first_process() == -EIO && current == NULL);
        assert(constructed == (fail_call >= 3));
        /* Even if pipe restore fails, usr1 restore must still be attempted. */
        assert(calls == (fail_call == 1 ? 1 : fail_call == 2 ? 3 : 4));
        assert(sigaction(SIGUSR1, NULL, &actual) == 0);
        assert(actual.sa_handler == (fail_call == 4 ? sigusr1_handler : host_handler));
        assert(sigaction(SIGPIPE, NULL, &actual) == 0);
        assert(actual.sa_handler == (fail_call == 3 ? SIG_IGN : host_handler));
    }
    assert(sigaction(SIGUSR1, &original_usr, NULL) == 0);
    assert(sigaction(SIGPIPE, &original_pipe, NULL) == 0);
}
''')

    # Round 5: candidate service-local predicate, NOT a production modification.
    # Extract the shipped read; change only its global-stop predicate in memory.
    service_read = read_body.replace('guest_threads_stopping()', 'service_kill_pending()')
    assert service_read != read_body
    probe('session-pending-kill-eintr-scope', r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <sys/types.h>
struct fd { int real_fd; };
#define _EINTR (-EINTR)
static bool pending[2];
static int selected, calls;
static bool service_kill_pending(void) { return pending[selected]; }
static int errno_map(void) { return -errno; }
static ssize_t injected_read(int fd, void *buf, size_t size) {
    (void)fd; (void)buf; (void)size;
    calls++;
    if (selected == 0 && calls == 1) { pending[0] = true; errno = EINTR; return -1; }
    return 1;
}
#define read injected_read
''' + service_read + '\nstatic bool guest_threads_stopping(void) { return false; }\n' + read_body.replace('realfs_read(', 'shipped_read(') + r'''
int main(void) {
    struct fd fd = {0}; char byte;
    assert(realfs_read(&fd, &byte, 1) == -EINTR && calls == 1);
    selected = 1; /* init/other service is unaffected; global stop stays unset. */
    assert(realfs_read(&fd, &byte, 1) == 1 && calls == 2 && !pending[1]);
    selected = 0; calls = 0; pending[0] = false;
    assert(shipped_read(&fd, &byte, 1) == 1 && calls == 2 && pending[0]);
}
''')

    # New service-specific test: retain pending SIGKILL across host entry.
    # No global stop, poll-wake candidate or pthread_cancel is introduced.
    probe('trial-session-pending-kill-before-host-entry', r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <pthread.h>
#include <semaphore.h>
#include <poll.h>
#include <unistd.h>
#include <sys/types.h>
struct fd { int real_fd; };
#define _EINTR (-EINTR)
static atomic_bool pending;
static sem_t past_check, enter_host;
static int input[2], finished[2];
static bool service_kill_pending(void) { return atomic_load(&pending); }
static int errno_map(void) { return -errno; }
static void wait_sem(sem_t *sem) {
    int res; do { res = sem_wait(sem); } while (res < 0 && errno == EINTR);
    assert(res == 0);
}
static ssize_t host_read_entry(int fd, void *buf, size_t size) {
    assert(sem_post(&past_check) == 0);
    wait_sem(&enter_host);
    /* Host wake has already been consumed, but guest pending remains true. */
    assert(service_kill_pending());
    return read(fd, buf, size);
}
#define read host_read_entry
''' + service_read + r'''
#undef read
static void *worker(void *arg) {
    (void)arg; struct fd fd = {input[0]}; char byte;
    assert(realfs_read(&fd, &byte, 1) == 1);
    assert(write(finished[1], "!", 1) == 1);
    return NULL;
}
int main(void) {
    assert(pipe(input) == 0 && pipe(finished) == 0);
    assert(sem_init(&past_check, 0, 0) == 0 && sem_init(&enter_host, 0, 0) == 0);
    pthread_t thread; assert(pthread_create(&thread, NULL, worker, NULL) == 0);
    wait_sem(&past_check);
    atomic_store(&pending, true);
    /* Deterministic shim for a wake delivered before entering host read.
     * No claim of executing deliver_signal or an actual guest Node process. */
    assert(sem_post(&enter_host) == 0);
    struct pollfd completion = {finished[0], POLLIN, 0};
    assert(poll(&completion, 1, 50) == 0 && atomic_load(&pending));
    assert(write(input[1], "!", 1) == 1); /* external release, not kill */
    assert(poll(&completion, 1, 1000) == 1);
    assert(pthread_join(thread, NULL) == 0);
}
''')

    child = function(init_source, 'int become_new_init_child(', '\nextern int console_major;')
    probe('session-new-child-keeps-init-and-clears-signals', r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include "misc.h"
#include "util/list.h"
struct task {
    int pid, clear_tid; void *vfork;
    unsigned blocked, pending, waiting; struct list queue;
};
static struct task init = {.pid = 1}, children[2], *current;
static int count;
static struct task *pid_get_task(int pid) { assert(pid == 1); return &init; }
static struct task *construct_task(struct task *parent) {
    assert(parent == &init && count < 2);
    struct task *task = &children[count++];
    task->pid = count + 1; task->clear_tid = 99; task->vfork = &init;
    task->blocked = task->pending = task->waiting = 255;
    return task;
}
''' + child + r'''
int main(void) {
    for (int n = 0; n < 2; n++) {
        assert(become_new_init_child() == 0 && current == &children[n]);
        assert(current->pid == n + 2 && !current->clear_tid && !current->vfork);
        assert(!current->blocked && !current->pending && !current->waiting);
        assert(list_empty(&current->queue) && init.pid == 1);
    }
}
''')

    unlink = function((root / 'fs/fake.c').read_text(),
                      'static int fakefs_unlink(', '\nstatic int fakefs_rmdir(')
    probe('session-fakefs-unlink-metadata-and-failure', r'''
#include <assert.h>
#include <stdbool.h>
#include <sys/types.h>
#include <limits.h>
struct fakefs_db { int transaction; };
struct mount { struct fakefs_db fakefs; };
#define _EROFS (-30)
#define FAKEFS_CHANGE_OP_UNLINK 1
static bool readonly;
static int host_error, metadata, orphaned;
static bool is_under_readonly_bind_mount(const char *p) { (void)p; return readonly; }
static bool bind_mount_translate_path_ex(const char *p, char *b, size_t n, bool *h) {
    (void)p; (void)b; (void)n; *h = false; return false;
}
static bool is_under_bind_mount(const char *p) { (void)p; return false; }
static void bind_mount_ensure_inode(struct fakefs_db *db, struct mount *m, const char *p) {
    (void)db; (void)m; (void)p; assert(0);
}
static int errno_map(void) { assert(0); return -1; }
static int unlink_host(const char *p) { (void)p; assert(0); return -1; }
#define unlink unlink_host
static void fakefs_record_change(const char *p, int op) { (void)p; (void)op; assert(0); }
static void db_begin_write(struct fakefs_db *db) { assert(!db->transaction); db->transaction = 1; }
static void db_rollback(struct fakefs_db *db) { assert(db->transaction); db->transaction = 0; }
static void db_commit(struct fakefs_db *db) { assert(db->transaction); db->transaction = 0; }
static int delete_data(struct mount *m, const char *p) {
    (void)p; assert(m->fakefs.transaction); return host_error;
}
static struct { int (*unlink)(struct mount *, const char *); } realfs = {delete_data};
static ino_t path_unlink(struct fakefs_db *db, const char *p) {
    (void)p; assert(db->transaction && !host_error); metadata++; return 42;
}
static void inode_check_orphaned(struct mount *m, ino_t ino) {
    assert(!m->fakefs.transaction && ino == 42); orphaned++;
}
''' + unlink + r'''
int main(void) {
    struct mount mount = {0};
    assert(fakefs_unlink(&mount, "/data/item") == 0);
    assert(metadata == 1 && orphaned == 1 && !mount.fakefs.transaction);
    host_error = -5;
    assert(fakefs_unlink(&mount, "/data/item") == -5);
    assert(metadata == 1 && orphaned == 1 && !mount.fakefs.transaction);
    readonly = true;
    assert(fakefs_unlink(&mount, "/data/item") == _EROFS);
}
''')

    # Round 6 candidate: deliberately not installed into fdops. The caller owns
    # O_NONBLOCK for the entire OFD lifetime, independently of guest_nonblock.
    # This is new code, not the Round 4 poll-then-blocking-read trial.
    service6_io = r'''
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <semaphore.h>
#include <stdlib.h>
struct service6_fd { int host; bool guest_nonblock; };
static bool fatal_pending;
static void (*before_operation)(void);
static void (*before_wait)(void);
static bool interrupted(struct guest_service *s) {
    return guest_service_stopping(s) || fatal_pending;
}
/* Host errno convention throughout the candidate; fdops must errno_map. */
static int service6_wait(struct guest_service *s, int fd, short events) {
    for (;;) {
        if (interrupted(s)) { errno = EINTR; return -1; }
        if (before_wait) before_wait();
        struct pollfd p[2] = {{fd, events, 0}, {guest_service_wake_fd(s), POLLIN, 0}};
        int n = poll(p, 2, -1);
        if (interrupted(s)) { errno = EINTR; return -1; }
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (p[0].revents & POLLNVAL) { errno = EBADF; return -1; }
        if (p[0].revents) return 0; /* includes HUP/ERR; operation determines result */
    }
}
static ssize_t service6_read(struct guest_service *s, struct service6_fd fd,
                             void *buf, size_t size) {
    for (;;) {
        if (interrupted(s)) { errno = EINTR; return -1; }
        if (before_operation) before_operation();
        ssize_t n = read(fd.host, buf, size);
        if (n >= 0) return n; /* preserve bytes/actual EOF, even if stop races */
        if (errno == EINTR) continue;
        if ((errno != EAGAIN && errno != EWOULDBLOCK) || fd.guest_nonblock) return -1;
        if (service6_wait(s, fd.host, POLLIN) < 0) return -1;
    }
}
/* Deterministic transport shims: no reliance on network routing/backlog timing.
 * These model the host nonblocking API, not execution of fs/sock.c. */
static atomic_int connect_calls, soerror_calls, accept_calls;
static int transport_error;
static int connect_once(int fd) {
    (void)fd; atomic_fetch_add(&connect_calls, 1); errno = EINPROGRESS; return -1;
}
static int connection_error(int fd, int *error) {
    (void)fd; atomic_fetch_add(&soerror_calls, 1); *error = transport_error; return 0;
}
static int accept_once(int fd) {
    atomic_fetch_add(&accept_calls, 1);
    char c; ssize_t n = read(fd, &c, 1);
    if (n < 0) return -1;
    assert(n == 1);
    return dup(fd); /* accepted endpoint; lifetime checked by the caller */
}
static int service6_connect(struct guest_service *s, struct service6_fd fd) {
    if (interrupted(s)) { errno = EINTR; return -1; }
    int n = connect_once(fd.host);
    if (n == 0 || (errno != EINPROGRESS && errno != EALREADY) || fd.guest_nonblock) return n;
    if (service6_wait(s, fd.host, POLLOUT) < 0) return -1;
    int error;
    if (connection_error(fd.host, &error) < 0) return -1;
    if (error) { errno = error; return -1; }
    return 0;
}
static int service6_accept(struct guest_service *s, struct service6_fd fd) {
    for (;;) {
        if (interrupted(s)) { errno = EINTR; return -1; }
        int client = accept_once(fd.host);
        if (client >= 0) return client;
        if (errno == EINTR) continue;
        if ((errno != EAGAIN && errno != EWOULDBLOCK) || fd.guest_nonblock) return -1;
        if (service6_wait(s, fd.host, POLLIN) < 0) return -1;
    }
}
static void nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    assert(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0);
    assert(fcntl(fd, F_GETFL) & O_NONBLOCK);
}
static void await_fence(struct guest_service *s) {
    struct timespec start, now;
    assert(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
    for (;;) {
        int err = guest_service_join_stopped(s);
        if (err == 0) return;
        assert(err == EBUSY);
        assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
        double elapsed = now.tv_sec - start.tv_sec + (now.tv_nsec - start.tv_nsec) / 1e9;
        assert(elapsed < 1.0); /* measured deadline, not unbounded retry */
        usleep(1000);
    }
}
'''
    probe('service6-nonblocking-read-connect-accept', service6_io + r'''
static sem_t reached, release_gate;
static int data_pipe[2];
static struct guest_service *service;
static struct service6_fd endpoint;
static int operation;
static atomic_int result, result_errno;
static void announce(void) { assert(sem_post(&reached) == 0); }
static void pause_wait(void) {
    announce(); assert(sem_wait(&release_gate) == 0);
}
static void pause_entry(void) {
    before_operation = NULL;
    announce(); assert(sem_wait(&release_gate) == 0);
}
static void *run_io(void *arg) {
    (void)arg; char c;
    int n = operation == 0 ? (int)service6_read(service, endpoint, &c, 1) :
            operation == 1 ? service6_connect(service, endpoint) : service6_accept(service, endpoint);
    assert(n == -1 && errno == EINTR); /* assert every waiter, not just the last */
    atomic_store(&result, n); atomic_store(&result_errno, errno);
    return NULL;
}
int main(void) {
    assert(sem_init(&reached, 0, 0) == 0 && sem_init(&release_gate, 0, 0) == 0);
    /* Empty read, connect-in-progress and empty accept. Stop during the
     * pre-poll gap; persistent readiness must survive entry and wake without input. */
    for (operation = 0; operation < 3; operation++) {
        assert(guest_service_new(&service) == 0 && pipe(data_pipe) == 0);
        nonblock(data_pipe[0]); nonblock(data_pipe[1]);
        endpoint = (struct service6_fd){data_pipe[operation == 1 ? 1 : 0], false};
        if (operation == 1) { /* no writable readiness until somebody drains */
            char bytes[4096] = {0};
            while (write(data_pipe[1], bytes, sizeof(bytes)) > 0) {}
            assert(errno == EAGAIN);
        }
        before_wait = pause_wait;
        pthread_t t;
        assert(guest_service_thread_create(service, &t, run_io, NULL, NULL) == 0);
        assert(guest_service_thread_create(service, &t, run_io, NULL, NULL) == 0);
        assert(sem_wait(&reached) == 0 && sem_wait(&reached) == 0);
        assert(guest_service_join_stopped(service) == EINVAL);
        assert(guest_service_request_stop(service) == 0);
        assert(guest_service_request_stop(service) == 0); /* idempotent; no repeated pipe write */
        assert(sem_post(&release_gate) == 0 && sem_post(&release_gate) == 0);
        await_fence(service);
        assert(atomic_load(&result) == -1 && atomic_load(&result_errno) == EINTR);
        assert(!guest_threads_stopping());
        assert(guest_service_destroy(service) == 0);
        close(data_pipe[0]); close(data_pipe[1]);
    }
    before_wait = NULL;
    /* Stop after check and before actual nonblocking read: EAGAIN returns
     * control to the loop; there is no blocking host-entry gap. */
    assert(guest_service_new(&service) == 0 && pipe(data_pipe) == 0);
    nonblock(data_pipe[0]); endpoint = (struct service6_fd){data_pipe[0], false};
    operation = 0; before_operation = pause_entry;
    pthread_t t;
    assert(guest_service_thread_create(service, &t, run_io, NULL, NULL) == 0);
    assert(sem_wait(&reached) == 0);
    assert(guest_service_request_stop(service) == 0);
    assert(guest_service_join_stopped(service) == EBUSY);
    assert(sem_post(&release_gate) == 0);
    await_fence(service); assert(atomic_load(&result_errno) == EINTR);
    assert(guest_service_destroy(service) == 0);
    close(data_pipe[0]); close(data_pipe[1]);
    assert(sem_destroy(&reached) == 0 && sem_destroy(&release_gate) == 0);
}
''', ['util/guest_threads.c'])

    probe('service6-data-eof-and-transport-errors', service6_io + r'''
int main(void) {
    struct guest_service *s;
    assert(guest_service_new(&s) == 0);
    int p[2]; assert(pipe(p) == 0); nonblock(p[0]);
    struct service6_fd fd = {p[0], true}; char b[16] = {0};
    assert(service6_read(s, fd, b, sizeof(b)) == -1 && errno == EAGAIN);
    assert(write(p[1], "abcdef", 6) == 6);
    fd.guest_nonblock = false;
    assert(service6_read(s, fd, b, 2) == 2);
    assert(service6_read(s, fd, b + 2, sizeof(b) - 2) == 4);
    assert(memcmp(b, "abcdef", 6) == 0); /* no fill-to-size or byte loss */
    assert(service6_read(s, fd, b, 0) == 0);
    close(p[1]); assert(service6_read(s, fd, b, sizeof(b)) == 0);
    close(p[0]);
    assert(pipe(p) == 0); nonblock(p[0]); nonblock(p[1]);
    struct service6_fd connector = {p[1], false};
    transport_error = ECONNREFUSED;
    assert(service6_connect(s, connector) == -1 && errno == ECONNREFUSED);
    transport_error = 0;
    assert(service6_connect(s, connector) == 0);
    connector.guest_nonblock = true;
    assert(service6_connect(s, connector) == -1 && errno == EINPROGRESS);
    assert(atomic_load(&connect_calls) == 3 && atomic_load(&soerror_calls) == 2);
    struct service6_fd listener = {p[0], true};
    assert(service6_accept(s, listener) == -1 && errno == EAGAIN);
    assert(write(p[1], "!", 1) == 1);
    listener.guest_nonblock = false;
    int client = service6_accept(s, listener);
    assert(client >= 0); assert(fcntl(client, F_GETFL) & O_NONBLOCK);
    close(client);
    fatal_pending = true;
    assert(service6_read(s, listener, b, sizeof(b)) == -1 && errno == EINTR);
    fatal_pending = false;
    assert(guest_service_request_stop(s) == 0); await_fence(s);
    assert(guest_service_destroy(s) == 0); close(p[0]); close(p[1]);
}
''', ['util/guest_threads.c'])

    probe('service6-fence-inheritance-and-live-init', r'''
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
#include <unistd.h>
#include <poll.h>
#include <stdatomic.h>
#include <time.h>
static struct guest_service *s;
static int gate[2], init_gate[2], entered[2];
static atomic_int child_ready;
static void *child(void *unused) {
    (void)unused; char c;
    atomic_store(&child_ready, 1);
    assert(read(gate[0], &c, 1) == 1); /* negative control remains blocked */
    return NULL;
}
static void *parent(void *unused) {
    (void)unused; pthread_t t;
    assert(guest_thread_create(&t, child, NULL, NULL) == 0); /* inherited scope */
    assert(write(entered[1], "!", 1) == 1);
    return NULL;
}
static void *init(void *unused) {
    (void)unused; char c; assert(read(init_gate[0], &c, 1) == 1); return NULL;
}
int main(void) {
    assert(pipe(gate) == 0 && pipe(init_gate) == 0 && pipe(entered) == 0);
    assert(guest_service_new(&s) == 0);
    pthread_t t; char c;
    assert(guest_thread_create(&t, init, NULL, NULL) == 0);
    assert(guest_service_thread_create(s, &t, parent, NULL, NULL) == 0);
    assert(read(entered[0], &c, 1) == 1);
    while (!atomic_load(&child_ready)) usleep(1000);
    assert(guest_service_request_stop(s) == 0);
    assert(guest_service_join_stopped(s) == EBUSY);
    assert(guest_service_destroy(s) == EBUSY); /* wake lifetime retained */
    struct pollfd wake = {guest_service_wake_fd(s), POLLIN, 0};
    assert(poll(&wake, 1, 0) == 1 && (wake.revents & POLLIN));
    assert(guest_service_thread_create(s, &t, child, NULL, NULL) == ECANCELED);
    assert(write(gate[1], "!", 1) == 1);
    int err = EBUSY;
    for (int i = 0; i < 1000 && err == EBUSY; i++) {
        err = guest_service_join_stopped(s); if (err == EBUSY) usleep(1000);
    }
    assert(err == 0 && !guest_threads_stopping());
    assert(guest_service_destroy(s) == 0); /* init is still blocked */
    struct guest_service *next;
    assert(guest_service_new(&next) == 0);
    assert(guest_service_thread_create(next, &t, parent, NULL, NULL) == 0);
    assert(read(entered[0], &c, 1) == 1);
    assert(write(gate[1], "!", 1) == 1);
    assert(guest_service_request_stop(next) == 0);
    err = EBUSY;
    for (int i = 0; i < 1000 && err == EBUSY; i++) {
        err = guest_service_join_stopped(next); if (err == EBUSY) usleep(1000);
    }
    assert(err == 0 && guest_service_destroy(next) == 0);
    assert(write(init_gate[1], "!", 1) == 1);
    guest_threads_request_stop();
    for (int i = 0; i < 1000; i++) {
        err = guest_threads_join_stopped(); if (!err) break;
        assert(err == EBUSY); usleep(1000);
    }
    assert(err == 0);
    close(gate[0]); close(gate[1]); close(init_gate[0]); close(init_gate[1]);
    close(entered[0]); close(entered[1]);
}
''', ['util/guest_threads.c'])

    # Inject host filesystem latency into the candidate's read, leaving a real
    # regular fd with verified O_NONBLOCK. This does not emulate EAGAIN pipes.
    # The shim has no stop branch, just as a synchronous vnode read has no
    # knowledge of our service's wake descriptor. Not an actual stalled disk.
    service6_stall = service6_io.replace(
        'static ssize_t service6_read(',
        r'''
static sem_t disk_entered, disk_release;
static ssize_t stalled_regular_read(int fd, void *buf, size_t size) {
    struct stat st;
    assert(fstat(fd, &st) == 0 && S_ISREG(st.st_mode));
    assert(fcntl(fd, F_GETFL) & O_NONBLOCK);
    assert(sem_post(&disk_entered) == 0);
    assert(sem_wait(&disk_release) == 0);
    return read(fd, buf, size);
}
static ssize_t service6_read(''').replace(
        'ssize_t n = read(fd.host, buf, size);',
        'ssize_t n = stalled_regular_read(fd.host, buf, size);')
    probe('trial-service6-nonblocking-regular-file-still-in-host-call',
          service6_stall + r'''
static struct guest_service *service;
static int fd, done[2];
static void *disk_reader(void *arg) {
    (void)arg; char c;
    assert(service6_read(service, (struct service6_fd){fd, false}, &c, 1) == 1);
    assert(c == 'x'); /* completed data cannot be replaced by fake EINTR/EOF */
    assert(write(done[1], "!", 1) == 1);
    return NULL;
}
int main(void) {
    /* Reference the other candidate functions without invoking transport;
     * this probe is solely the regular-file host-call boundary. */
    (void)service6_connect; (void)service6_accept;
    assert(sem_init(&disk_entered, 0, 0) == 0 && sem_init(&disk_release, 0, 0) == 0);
    char path[] = "/tmp/service6-file-XXXXXX";
    fd = mkstemp(path); assert(fd >= 0); assert(unlink(path) == 0);
    assert(write(fd, "x", 1) == 1 && lseek(fd, 0, SEEK_SET) == 0);
    nonblock(fd);
    struct pollfd file_ready = {fd, POLLIN, 0};
    assert(poll(&file_ready, 1, 0) == 1 && (file_ready.revents & POLLIN));
    assert(pipe(done) == 0 && guest_service_new(&service) == 0);
    pthread_t t;
    assert(guest_service_thread_create(service, &t, disk_reader, NULL, NULL) == 0);
    assert(sem_wait(&disk_entered) == 0);
    assert(guest_service_request_stop(service) == 0);
    struct pollfd p = {done[0], POLLIN, 0};
    assert(poll(&p, 1, 50) == 0); /* observation only, not an infinity claim */
    assert(guest_service_join_stopped(service) == EBUSY);
    struct pollfd wake = {guest_service_wake_fd(service), POLLIN, 0};
    assert(poll(&wake, 1, 0) == 1 && (wake.revents & POLLIN));
    assert(guest_service_destroy(service) == EBUSY);
    /* Only the host storage completion shim releases this call. Stop cannot
     * execute the loop's next check until read returns. */
    assert(sem_post(&disk_release) == 0);
    assert(poll(&p, 1, 1000) == 1);
    await_fence(service);
    assert(guest_service_destroy(service) == 0);
    close(fd); close(done[0]); close(done[1]);
    assert(sem_destroy(&disk_entered) == 0 && sem_destroy(&disk_release) == 0);
}
''', ['util/guest_threads.c'])

    probe('service6-readiness-consumed-before-nonblocking-retry', service6_io + r'''
static sem_t reached, proceed;
static int input[2], attempts;
static struct guest_service *s;
static void pause_wait(void) {
    assert(sem_post(&reached) == 0 && sem_wait(&proceed) == 0);
}
static void pause_second_attempt(void) {
    if (++attempts == 2)
        assert(sem_post(&reached) == 0 && sem_wait(&proceed) == 0);
}
static void *reader(void *unused) {
    (void)unused; char c;
    assert(service6_read(s, (struct service6_fd){input[0], false}, &c, 1) == -1);
    assert(errno == EINTR && attempts == 2);
    return NULL;
}
int main(void) {
    (void)service6_connect; (void)service6_accept;
    assert(sem_init(&reached, 0, 0) == 0 && sem_init(&proceed, 0, 0) == 0);
    assert(pipe(input) == 0); nonblock(input[0]);
    assert(guest_service_new(&s) == 0);
    before_wait = pause_wait; before_operation = pause_second_attempt;
    pthread_t t;
    assert(guest_service_thread_create(s, &t, reader, NULL, NULL) == 0);
    assert(sem_wait(&reached) == 0); /* first operation got EAGAIN */
    assert(write(input[1], "a", 1) == 1 && sem_post(&proceed) == 0);
    assert(sem_wait(&reached) == 0); /* poll ready, before the second operation */
    char c;
    assert(read(input[0], &c, 1) == 1 && c == 'a'); /* competing reader wins */
    assert(guest_service_request_stop(s) == 0);
    assert(sem_post(&proceed) == 0);
    await_fence(s); /* no rescue write: second operation is genuinely nonblocking */
    assert(guest_service_destroy(s) == 0);
    close(input[0]); close(input[1]);
    assert(sem_destroy(&reached) == 0 && sem_destroy(&proceed) == 0);
}
''', ['util/guest_threads.c'])

    # Inject wake failure into the actual registry implementation, not a
    # substitute service implementation. The stop flag must stay set, while
    # the same stop request remains recoverable after the failed write.
    registry6 = (root / 'util/guest_threads.c').read_text()
    probe('service6-wake-write-failure-and-retry', r'''
#include <unistd.h>
#include <errno.h>
#include <assert.h>
#include <poll.h>
static int fail_write;
static ssize_t wake_write(int fd, const void *buf, size_t n) {
    if (fail_write) { errno = EINTR; return -1; }
    return write(fd, buf, n);
}
#define write wake_write
''' + registry6 + r'''
int main(void) {
    struct guest_service *s;
    assert(guest_service_new(&s) == 0);
    fail_write = 1;
    assert(guest_service_request_stop(s) == EINTR && guest_service_stopping(s));
    struct pollfd p = {guest_service_wake_fd(s), POLLIN, 0};
    assert(poll(&p, 1, 0) == 0);
    fail_write = 0;
    assert(guest_service_request_stop(s) == 0);
    assert(poll(&p, 1, 0) == 1 && (p.revents & POLLIN));
    for (int i = 0; i < 100000; i++) assert(guest_service_request_stop(s) == 0);
    assert(guest_service_destroy(s) == 0);
}
''')

    probe('service6-guest-blocking-read-until-data', service6_io + r'''
static sem_t waiting, proceed;
static struct guest_service *s;
static int input[2], done[2];
static void pause_wait(void) {
    assert(sem_post(&waiting) == 0 && sem_wait(&proceed) == 0);
}
static void *reader(void *unused) {
    (void)unused; char b[16];
    ssize_t n = service6_read(s, (struct service6_fd){input[0], false}, b, sizeof(b));
    assert(n == 3 && memcmp(b, "abc", 3) == 0);
    assert(write(done[1], "!", 1) == 1); return NULL;
}
int main(void) {
    (void)service6_connect; (void)service6_accept;
    assert(sem_init(&waiting, 0, 0) == 0 && sem_init(&proceed, 0, 0) == 0);
    assert(guest_service_new(&s) == 0 && pipe(input) == 0 && pipe(done) == 0);
    nonblock(input[0]); before_wait = pause_wait;
    pthread_t t;
    assert(guest_service_thread_create(s, &t, reader, NULL, NULL) == 0);
    assert(sem_wait(&waiting) == 0);
    struct pollfd p = {done[0], POLLIN, 0};
    assert(poll(&p, 1, 0) == 0); /* internal EAGAIN was not exposed to guest */
    assert(write(input[1], "abc", 3) == 3 && sem_post(&proceed) == 0);
    assert(poll(&p, 1, 1000) == 1);
    assert(guest_service_request_stop(s) == 0); await_fence(s);
    assert(guest_service_destroy(s) == 0);
    close(input[0]); close(input[1]); close(done[0]); close(done[1]);
    assert(sem_destroy(&waiting) == 0 && sem_destroy(&proceed) == 0);
}
''', ['util/guest_threads.c'])

    # Round 7: production control predicates + actual service completion registry.
    # These Linux gates do not boot a guest or establish iOS acceptance.
    session_header = Path(__file__).resolve().parents[3] / 'app/ios/Runner/ShellBoxSession.h'
    (root / 'ShellBoxSession.h').write_text(session_header.read_text())
    session7 = r'''
#include "ShellBoxSession.h"
#include "util/guest_threads.h"
#include <assert.h>
#include <errno.h>
#include <semaphore.h>
#include <time.h>
#include <unistd.h>
static sem_t entered, release_worker;
static int owner;
static void *blocked_worker(void *unused) {
    (void)unused;
    guest_thread_bind_owner(&owner);
    assert(!guest_current_service_stopping());
    assert(sem_post(&entered) == 0);
    assert(sem_wait(&release_worker) == 0);
    assert(guest_current_service_stopping());
    return NULL;
}
static struct guest_service *blocked_service(void) {
    struct guest_service *s;
    assert(sem_init(&entered, 0, 0) == 0 && sem_init(&release_worker, 0, 0) == 0);
    assert(guest_service_new(&s) == 0);
    pthread_t worker;
    assert(guest_service_thread_create(s, &worker, blocked_worker, NULL, NULL) == 0);
    assert(sem_wait(&entered) == 0);
    assert(guest_service_has_owner(s, &owner));
    assert(guest_service_request_stop(s) == 0);
    assert(guest_service_join_stopped(s) == EBUSY);
    return s;
}
static void finish(struct guest_service *s) {
    assert(sem_post(&release_worker) == 0);
    int err = EBUSY;
    for (int i = 0; i < 1000 && err == EBUSY; i++) {
        err = guest_service_join_stopped(s);
        if (err == EBUSY) usleep(1000);
    }
    assert(err == 0 && guest_service_destroy(s) == 0);
    assert(sem_destroy(&entered) == 0 && sem_destroy(&release_worker) == 0);
}
'''
    probe('session7-stop-timeout-enters-StopBlocked', session7 + r'''
int main(void) {
    struct guest_service *s = blocked_service();
    usleep(50000); /* accelerated host deadline, not a claim of bounded read */
    bool complete = guest_service_join_stopped(s) == 0;
    enum sb_phase phase = sb_stop_result(complete);
    assert(phase == SB_STOP_BLOCKED && !complete);
    assert(guest_service_destroy(s) == EBUSY);
    finish(s);
}
''', ['util/guest_threads.c'])
    probe('session7-StopBlocked-rejects-initialization', session7 + r'''
int main(void) {
    struct guest_service *s = blocked_service();
    enum sb_phase phase = sb_stop_result(false);
    assert(!sb_can_initialize(phase, false));
    assert(!sb_can_initialize(phase, true));
    assert(!sb_can_initialize(SB_STARTING, false));
    assert(!sb_can_initialize(SB_RUNNING, false));
    assert(guest_service_has_owner(s, &owner));
    finish(s);
}
''', ['util/guest_threads.c'])
    probe('session7-StopBlocked-rejects-reset', session7 + r'''
int main(void) {
    struct guest_service *s = blocked_service();
    assert(!sb_can_initialize(sb_stop_result(false), false));
    assert(!sb_can_initialize(SB_RESETTING, false));
    assert(!sb_can_initialize(SB_STOPPED, true));
    assert(guest_service_destroy(s) == EBUSY); /* no resource release on reset refusal */
    finish(s);
}
''', ['util/guest_threads.c'])
    probe('session7-retry-stop-and-reuse-guest', session7 + r'''
int main(void) {
    struct guest_service *s = blocked_service();
    enum sb_phase phase = sb_stop_result(false);
    assert(sb_can_stop(phase, false));
    assert(!sb_can_stop(phase, true)); /* original request still owns the queue */
    assert(guest_service_request_stop(s) == 0); /* same handle, no init */
    assert(guest_service_join_stopped(s) == EBUSY);
    finish(s);
    phase = sb_stop_result(true);
    assert(phase == SB_STOPPED && sb_can_initialize(phase, false));
    assert(!guest_threads_stopping()); /* admission for next session remains open */
    s = blocked_service(); finish(s);
}
''', ['util/guest_threads.c'])

    probe('session8-running-rejects-second-start-confirmed-stop-allows-new-service', r'''
#include "ShellBoxSession.h"
#include "util/guest_threads.h"
#include <assert.h>
int main(void) {
    struct guest_service *service = NULL;
    enum sb_phase phase = SB_INSTALLED;
    assert(sb_can_initialize(phase, false));
    assert(guest_service_new(&service) == 0);
    phase = SB_RUNNING;
    struct guest_service *original = service;
    assert(!sb_can_initialize(phase, false));
    assert(service == original); /* rejected start retained the same handle */
    assert(guest_service_request_stop(service) == 0);
    assert(guest_service_join_stopped(service) == 0);
    assert(guest_service_destroy(service) == 0);
    service = NULL;
    phase = sb_stop_result(true);
    assert(sb_can_initialize(phase, false));
    assert(guest_service_new(&service) == 0);
    assert(guest_service_request_stop(service) == 0);
    assert(guest_service_join_stopped(service) == 0);
    assert(guest_service_destroy(service) == 0);
}
''', ['util/guest_threads.c'])

    # Execute the exact production reset command with /root relocated to a
    # disposable host tree. This covers selection/traversal, not fakefs SQLite.
    reset_source = root / 'reset-command.c'
    reset_source.write_text(r'''
#include "ShellBoxSession.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    puts(sb_reset_command(atoi(argv[1]), atoi(argv[2])));
}
''')
    reset_binary = root / 'reset-command'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I' + str(root),
                    str(reset_source), '-o', str(reset_binary)], check=True)
    import os
    for ui in (0, 1):
        for plugins in (0, 1):
            tree = root / f'reset-{ui}-{plugins}'
            tree.mkdir()
            outside = root / f'outside-{ui}-{plugins}'
            outside.mkdir()
            (outside / 'sentinel').write_text('outside')
            ui_paths = ['.dsh/dsh-go/ui.json', '.dsh/skills/user/skill', '.agents/skills/user/skill']
            plugin_paths = ['.dsh/profiles/plugin/config', '.dsh/cordis.patch.yml', '.dsh/.env']
            deleted = ['.dsh/skills-old/data', '.dsh/chats/session', 'workspace/file', '.bash_history']
            for name in ui_paths + plugin_paths + deleted:
                target = tree / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('user data')
            os.symlink(outside, tree / 'outside-link')
            os.link(tree / ui_paths[0], tree / 'unkept-hardlink')
            inode = (tree / ui_paths[0]).stat().st_ino
            command = subprocess.check_output([str(reset_binary), str(ui), str(plugins)], text=True)
            command = command.replace('/root', str(tree))
            subprocess.run(['/bin/sh', '-c', command], check=True)
            assert (outside / 'sentinel').read_text() == 'outside'
            assert not (tree / 'outside-link').is_symlink()
            assert all(not (tree / name).exists() for name in deleted)
            assert all((tree / name).exists() == bool(ui) for name in ui_paths)
            assert all((tree / name).exists() == bool(plugins) for name in plugin_paths)
            if ui:
                assert (tree / ui_paths[0]).stat().st_ino == inode
    print('PASS session7-reset-keep-selection-symlinks-and-hardlinks (host find, not fakefs)', flush=True)

# Round 8: evaluate the exact embedded startup JavaScript against a guest-fs
# fixture. This checks provisioning, not DNS/TLS reachability under ShellBox.
import json
plugin = (Path(__file__).resolve().parents[3] / 'app/ios/Runner/ShellBoxPlugin.m').read_text()
command_line = next(line.strip() for line in plugin.splitlines() if '@"cd /root &&' in line)
command = json.loads(command_line[:command_line.rindex('", port]') + 1][1:])
script = command.split("node -e '", 1)[1].split("' && exec", 1)[0]
fixture = r"""
const vm = require('vm'), assert = require('assert');
const script = SCRIPT;
for (const existing of [false, true]) {
  const files = new Map(existing ? [
    ['/etc/resolv.conf', 'nameserver 9.9.9.9\n'],
    ['/etc/hosts', '127.0.0.1 custom\n'],
    ['/etc/ssl/certs/ca-certificates.crt', 'custom ca\n']
  ] : [['/etc/resolv.conf', ''], ['/etc/hosts', '']]);
  const before = new Map(files);
  const fs = {
    existsSync: p => files.has(p),
    statSync: p => ({size: files.get(p).length}),
    writeFileSync: (p,v) => files.set(p,v),
    mkdirSync: () => {}
  };
  const logs = [];
  vm.runInNewContext(script, {
    process: {version:'v24.22.3', exit: () => {throw Error('version');}},
    require: m => m === 'fs' ? fs : require(m),
    console: {log: line => logs.push(line)}
  });
  if (existing) assert.deepStrictEqual(files, before);
  else {
    assert.strictEqual(files.get('/etc/resolv.conf'), 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n');
    assert.strictEqual(files.get('/etc/hosts'), '127.0.0.1 localhost\n::1 localhost\n');
    assert(files.get('/etc/ssl/certs/ca-certificates.crt').includes('-----BEGIN CERTIFICATE-----'));
  }
  assert.deepStrictEqual(logs, ['DSH_GO_NETWORK_CONFIG=ready', 'DSH_GO_NODE=v24.22.3']);
}
""".replace('SCRIPT', json.dumps(script))
subprocess.run(['node', '-e', fixture], check=True)
print('PASS session8-startup-network-provisioning-empty-and-existing (host Node fixture, not guest HTTPS)', flush=True)
