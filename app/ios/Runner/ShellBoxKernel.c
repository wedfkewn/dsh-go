#define ISH_INTERNAL
#include "ShellBoxKernel.h"
#include "kernel/task.h"
#include "ShellBoxBridge.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/signal.h"
#include "fs/fd.h"
#include "fs/path.h"
#include <sys/stat.h>
#include "fs/real.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "util/guest_threads.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Pinned kernel/exit.c exposes do_wait but has no public declaration. */
extern int do_wait(int, pid_t_, struct siginfo_ *, struct rusage_ *, int);
enum { P_ALL_ = 0, WNOHANG_ = 1, WEXITED_ = 4 };

/* PID 1 executes a host-side wait loop, never an exiting shell. Creation and
 * reaping share this lock. It remains a guest parent for the Runner lifetime. */
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t boot_cond = PTHREAD_COND_INITIALIZER;
static bool boot_attempted, boot_done;
static int boot_error;
static atomic_int command_status;
static atomic_int command_pid;
static char *boot_root;
static void *init_worker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&init_lock);
    int err = mount_root(&fakefs, boot_root);
    if (!err) err = become_first_process();
    if (!err) {
        current->thread = pthread_self();
        guest_thread_bind_owner(current);
        generic_mkdirat(AT_PWD, "/dev", 0755);
        const char *names[] = {"/dev/null", "/dev/zero", "/dev/random", "/dev/urandom"};
        int minors[] = {DEV_NULL_MINOR, DEV_ZERO_MINOR, DEV_RANDOM_MINOR, DEV_URANDOM_MINOR};
        for (unsigned i = 0; i < 4 && !err; i++) {
            int result = generic_mknodat(AT_PWD, names[i], S_IFCHR | 0666, dev_make(MEM_MAJOR, minors[i]));
            if (result && result != _EEXIST) err = result;
        }
        generic_mkdirat(AT_PWD, "/proc", 0755);
        if (!err) err = do_mount(&procfs, "proc", "/proc", "", 0);
    }
    /* /dev already carries Linux nodes from the fakefs archive. */
    boot_error = err;
    boot_done = true;
    pthread_cond_broadcast(&boot_cond);
    pthread_mutex_unlock(&init_lock);
    if (err) return NULL; /* terminal boot failure; never retry mount/init */
    for (;;) {
        pthread_mutex_lock(&init_lock);
        struct siginfo_ info = {0};
        while (do_wait(P_ALL_, 0, &info, NULL, WEXITED_ | WNOHANG_) == 0 && info.child.pid)
            memset(&info, 0, sizeof(info));
        pthread_mutex_unlock(&init_lock);
        guest_threads_reap();
        usleep(10000);
    }
}
int dsh_shellbox_boot(const char *root) {
    pthread_mutex_lock(&init_lock);
    if (!boot_attempted) {
        boot_attempted = true;
        boot_root = strdup(root);
        pthread_t thread;
        int err = boot_root ? guest_thread_create(&thread, init_worker, NULL, NULL) : ENOMEM;
        if (err) { boot_error = err; boot_done = true; }
    }
    while (!boot_done) pthread_cond_wait(&boot_cond, &init_lock);
    int err = boot_error;
    pthread_mutex_unlock(&init_lock);
    return err;
}
struct output_pump { int fd, stream; dsh_shellbox_output output; };
static void *pump(void *arg) {
    struct output_pump *p = arg;
    char bytes[4096];
    ssize_t count;
    while ((count = read(p->fd, bytes, sizeof(bytes))) != 0) {
        if (count > 0) p->output(bytes, (size_t)count, p->stream);
        else if (errno != EINTR) break;
    }
    p->output(NULL, 0, p->stream);
    close(p->fd);
    free(p);
    return NULL;
}
struct launch { char *command, *env; dsh_shellbox_output output; };
static int output_fd(int index, dsh_shellbox_output output) {
    int pair[2];
    if (pipe(pair)) return -errno;
    struct output_pump *p = malloc(sizeof(*p));
    if (!p) { close(pair[0]); close(pair[1]); return -ENOMEM; }
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (!fd) { free(p); close(pair[0]); close(pair[1]); return -ENOMEM; }
    *p = (struct output_pump){pair[0], index, output};
    fd->real_fd = pair[1]; fd->dir = NULL;
    fd->stat.mode = S_IFIFO | 0600; fd->type = S_IFIFO; fd->flags = O_WRONLY_;
    pthread_t thread;
    int err = guest_thread_create(&thread, pump, p, NULL);
    if (err) { close(pair[0]); free(p); fd_close(fd); return -err; }
    /* The service fence joins this pump after EOF, before another session can
     * reuse the stream framers. No detached output worker outlives stop. */
    current->files->files[index] = fd;
    return 0;
}
static void command_exit(struct task *task, int status) {
    /* The last exiting group thread may not be the leader. Exit is command
     * result evidence, never the service completion fence. */
    if (task->tgid == atomic_load(&command_pid))
        atomic_store(&command_status, status);
}
static void *launch_worker(void *arg) {
    struct launch *launch = arg;
    pthread_mutex_lock(&init_lock);
    int err = become_new_init_child();
    if (!err) { current->thread = pthread_self(); guest_thread_bind_owner(current); atomic_store(&command_pid, current->pid); }
    pthread_mutex_unlock(&init_lock);
    if (err) { atomic_store(&command_status, 127 << 8); free(launch->command); free(launch->env); free(launch); return NULL; }
    /* stdin is EOF; stdout and stderr have independent, continuously drained
     * pipes. realfs fdops preserve Linux guest write and poll semantics. */
    struct fd *input = generic_open("/dev/null", O_RDONLY_, 0);
    if (IS_ERR(input)) err = PTR_ERR(input);
    else current->files->files[0] = input;
    if (!err) err = output_fd(1, launch->output);
    if (!err) err = output_fd(2, launch->output);
    size_t length = strlen(launch->command);
    char *argv = malloc(length + 13);
    if (!argv) err = -ENOMEM;
    if (!err && guest_current_service_stopping()) err = _EINTR;
    if (!err) {
        memcpy(argv, "/bin/sh\0-c\0", 11);
        memcpy(argv + 11, launch->command, length + 1);
        argv[length + 12] = 0;
        err = do_execve("/bin/sh", 3, argv, launch->env);
    }
    free(argv); free(launch->command); free(launch->env); free(launch);
    if (err) do_exit(127 << 8);
    task_run_current();
    return NULL;
}
int dsh_shellbox_launch(const char *command, const char *environment,
        dsh_shellbox_output output, struct guest_service **out) {
    struct launch *launch = calloc(1, sizeof(*launch));
    if (!launch) return ENOMEM;
    size_t size = 0;
    while (environment[size]) size += strlen(environment + size) + 1;
    launch->command = strdup(command);
    launch->env = malloc(size + 1); launch->output = output;
    if (!launch->command || !launch->env) {
        free(launch->command); free(launch->env); free(launch); return ENOMEM;
    }
    memcpy(launch->env, environment, size + 1);
    int err = guest_service_new(out);
    if (!err) {
        atomic_store(&command_status, -1);
        atomic_store(&command_pid, 0);
        exit_hook = command_exit;
        pthread_t thread;
        err = guest_service_thread_create(*out, &thread, launch_worker, launch, NULL);
        if (err) { guest_service_request_stop(*out); guest_service_destroy(*out); *out = NULL; }
    }
    if (err) { free(launch->command); free(launch->env); free(launch); }
    return err;
}
int dsh_shellbox_request_stop(struct guest_service *service) {
    int err = guest_service_request_stop(service);
    lock(&pids_lock);
    for (int id = 2; id < MAX_PID; id++) {
        struct task *task = pid_get_task(id);
        if (task && guest_service_has_owner(service, task) && !task->zombie)
            send_signal(task, SIGKILL_, SIGINFO_NIL);
    }
    unlock(&pids_lock);
    return err;
}
int dsh_shellbox_finish_stop(struct guest_service *service) {
    int err = guest_service_join_stopped(service);
    if (err) return err;
    /* All service workers joined. Reap zombies as PID 1 before dropping handle;
     * serialized with its wait loop and with construction. */
    pthread_mutex_lock(&init_lock);
    struct task *saved = current;
    current = pid_get_task(1);
    struct siginfo_ info = {0};
    while (do_wait(P_ALL_, 0, &info, NULL, WEXITED_ | WNOHANG_) == 0 && info.child.pid)
        memset(&info, 0, sizeof(info));
    current = saved;
    pthread_mutex_unlock(&init_lock);
    return guest_service_destroy(service);
}
int dsh_shellbox_command_status(void) { return atomic_load(&command_status); }

int dsh_shellbox_command_pid(void) { return atomic_load(&command_pid); }
