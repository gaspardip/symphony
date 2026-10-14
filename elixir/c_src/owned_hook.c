/* Local hook process-group owner. This is lifecycle control, not a sandbox. */
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define GRACE_MS 250
#define VERIFY_MS 2000
#define CHUNK 16384

/* Trigger: completed, deadline, owner gone, helper signal, internal failure. */
enum trigger { NONE = -1, COMPLETED = 0, DEADLINE, OWNER_GONE, SIGNALLED, FAILED };
enum phase { NO_ERROR = 0, SETUP, GROUP, CONTROL, WAIT_CHILD, SEND_SIGNAL,
             REAP, GROUP_PROBE, OUTPUT, EXEC, CLOCK };
static volatile sig_atomic_t interrupted;
static void stop_signal(int sig) { interrupted = sig; }

struct owner {
    pid_t child;
    int grouped, reaped, reap_confirmed, seen_exit, status, input, output, gate;
    int started, channel, control_open, output_eof, killed, confirmed, final_queued;
    int stream, error_output, error_eof, write_ack, output_credit, error_first;
    uint32_t write_id;
    unsigned char input_pending[CHUNK];
    size_t input_size, input_offset;
    enum trigger trigger;
    enum phase phase;
    int reason, closure_error;
    int64_t deadline, stopping, finish_deadline;
    unsigned char pending[CHUNK + 256];
    size_t pending_size, pending_offset;
    unsigned char control[CHUNK + 32];
    size_t control_size;
};

static int64_t clock_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int owned_pipe(int p[2]) {
    if (pipe(p) < 0) return -1;
    if (fcntl(p[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(p[1], F_SETFD, FD_CLOEXEC) < 0) {
        int cause = errno;
        close(p[0]); close(p[1]); errno = cause; return -1;
    }
    return 0;
}

static void remember(struct owner *o, enum phase phase, int reason) {
    /* Signal/probe diagnostics stay visible. Only a later exact reap, group
       ESRCH and output EOF can resolve them. Every other failure invalidates
       that proof, even when a signal/probe diagnostic was recorded first. */
    if (phase != SEND_SIGNAL && phase != GROUP_PROBE) o->closure_error = 1;
    if (o->phase == NO_ERROR) { o->phase = phase; o->reason = reason; }
}

static void packet(struct owner *o, char kind, const void *data, size_t size) {
    uint32_t length = htonl((uint32_t)size + 1);
    memcpy(o->pending, &length, 4);
    o->pending[4] = (unsigned char)kind;
    memcpy(o->pending + 5, data, size);
    o->pending_size = size + 5;
    o->pending_offset = 0;
}

static void flush_packet(struct owner *o) {
    if (!o->channel || o->pending_size == 0) return;
    ssize_t n = write(STDOUT_FILENO, o->pending + o->pending_offset,
                      o->pending_size - o->pending_offset);
    if (n > 0) {
        o->pending_offset += (size_t)n;
        if (o->pending_offset == o->pending_size) o->pending_size = 0;
    } else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        remember(o, OUTPUT, errno);
        o->channel = 0; o->pending_size = 0;
    }
}

static void signal_owned(struct owner *o, int sig) {
    /* Never signal a numeric PID/PGID after releasing our child identity. */
    if (o->reaped || o->child <= 1) return;
    pid_t target = o->grouped ? -o->child : o->child;
    if (kill(target, sig) < 0 && errno != ESRCH) remember(o, SEND_SIGNAL, errno);
}

static void begin_stop(struct owner *o, enum trigger trigger, int64_t now) {
    if (o->trigger != NONE) return;
    o->trigger = trigger;
    o->stopping = now;
    o->finish_deadline = now + GRACE_MS + VERIFY_MS;
    if (o->gate >= 0) { close(o->gate); o->gate = -1; }
    if (o->input >= 0) { close(o->input); o->input = -1; }
    signal_owned(o, SIGTERM);
}

static void observe_child(struct owner *o) {
    if (o->child <= 0 || o->reaped || o->seen_exit) return;
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)o->child, &info, WEXITED | WNOHANG | WNOWAIT) < 0) {
        if (errno != EINTR) {
            remember(o, WAIT_CHILD, errno);
            if (errno == ECHILD) o->reaped = 1; /* Never signal a released identity. */
        }
    } else if (info.si_pid == o->child) {
        o->seen_exit = 1;
        o->status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
    }
}

static void complete_cleanup(struct owner *o, int64_t now) {
    if (o->trigger == NONE) return;
    if (!o->killed && now - o->stopping >= GRACE_MS) {
        signal_owned(o, SIGKILL);
        o->killed = 1;
    }
    if (o->killed && !o->reaped && o->seen_exit) {
        int status;
        pid_t result = waitpid(o->child, &status, WNOHANG);
        if (result == o->child) { o->reaped = 1; o->reap_confirmed = 1; }
        else if (result < 0 && errno != EINTR) {
            remember(o, REAP, errno);
            if (errno == ECHILD) o->reaped = 1;
        }
    }
    if (o->reaped && !o->confirmed) {
        if (!o->grouped) o->confirmed = 1;
        else if (kill(-o->child, 0) < 0) {
            if (errno == ESRCH) o->confirmed = 1;
            else remember(o, GROUP_PROBE, errno);
        }
        /* A positive probe after reap may be a recycled group. Do not signal it. */
    }
}

static void control_packet(struct owner *o, const unsigned char *data, size_t size, int64_t now) {
    if (o->stream && size == 1 && data[0] == 'A') {
        if (o->trigger != NONE) return; /* Cleanup drains independently of credits. */
        if (o->output_credit == 0) { o->output_credit = 1; return; }
    }
    if (o->stream && size > 5 && size <= CHUNK + 5 && data[0] == 'I' && o->started &&
        o->trigger == NONE && o->input >= 0 && o->input_size == 0 && !o->write_ack) {
        memcpy(&o->write_id, data + 1, 4);
        memcpy(o->input_pending, data + 5, size - 5);
        o->input_size = size - 5; o->input_offset = 0; return;
    }
    if (o->stream && size == 1 && data[0] == 'E' && o->input_size == 0 && !o->write_ack) {
        if (o->input >= 0) { close(o->input); o->input = -1; }
        return;
    }
    if (size == 1 && data[0] == 'C') { begin_stop(o, OWNER_GONE, now); return; }
    if (size == 1 && data[0] == 'T') { begin_stop(o, DEADLINE, now); return; }
    if (size > 1 && size < 24 && data[0] == 'G' && !o->started && o->trigger == NONE) {
        char text[24], *end;
        memcpy(text, data + 1, size - 1); text[size - 1] = 0;
        errno = 0;
        long remaining = strtol(text, &end, 10);
        if (errno || *end || remaining <= 0) { begin_stop(o, DEADLINE, now); return; }
        if (remaining < o->deadline - now) o->deadline = now + remaining;
        if (now >= o->deadline) { begin_stop(o, DEADLINE, now); return; }
        if (write(o->gate, "G", 1) != 1) {
            remember(o, CONTROL, errno); begin_stop(o, FAILED, now); return;
        }
        close(o->gate); o->gate = -1; o->started = 1; o->output_credit = 1;
        if (o->stream) packet(o, 'B', "", 0);
        return;
    }
    remember(o, CONTROL, EPROTO); begin_stop(o, FAILED, now);
}

static void read_control(struct owner *o, int64_t now) {
    if (!o->control_open) return;
    /* Unreachable: a rejected frame closes control before the buffer fills.
       GCC cannot see that across calls, and fortify needs the bound. */
    if (o->control_size >= sizeof(o->control)) return;
    /* A single bounded read cannot starve the native deadline. */
    ssize_t n = read(STDIN_FILENO, o->control + o->control_size,
                     sizeof(o->control) - o->control_size);
    if (n == 0) { o->control_open = 0; begin_stop(o, OWNER_GONE, now); return; }
    if (n < 0) {
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
            o->control_open = 0; remember(o, CONTROL, errno); begin_stop(o, OWNER_GONE, now);
        }
        return;
    }
    o->control_size += (size_t)n;
    while (o->control_size >= 4) {
        uint32_t length;
        memcpy(&length, o->control, 4); length = ntohl(length);
        if (length == 0 || length > (o->stream ? CHUNK + 5 : 24)) {
            o->control_open = 0; remember(o, CONTROL, EPROTO); begin_stop(o, FAILED, now); return;
        }
        if (o->control_size < (size_t)length + 4) return;
        control_packet(o, o->control + 4, length, now);
        o->control_size -= (size_t)length + 4;
        memmove(o->control, o->control + length + 4, o->control_size);
    }
}

static void flush_input(struct owner *o, int64_t now) {
    if (o->trigger != NONE || o->input < 0 || o->input_size == 0) return;
    ssize_t count = write(o->input, o->input_pending + o->input_offset, o->input_size - o->input_offset);
    if (count > 0) {
        o->input_offset += (size_t)count;
        if (o->input_offset == o->input_size) { o->input_size = 0; o->write_ack = 1; }
    } else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        remember(o, CONTROL, errno); begin_stop(o, FAILED, now);
    }
}

static void read_error(struct owner *o) {
    if (!o->stream || o->error_eof || (o->trigger == NONE && !o->output_credit) || (o->channel && o->pending_size != 0)) return;
    unsigned char data[CHUNK];
    ssize_t n = read(o->error_output, data, sizeof(data));
    if (n > 0 && o->channel && (o->trigger == NONE || o->trigger == COMPLETED)) {
        packet(o, 'S', data, (size_t)n); o->output_credit = 0;
    }
    else if (n == 0) o->error_eof = 1;
    else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        remember(o, OUTPUT, errno); o->error_eof = 1;
    }
}

static void read_output(struct owner *o) {
    if (o->output_eof || (o->stream && o->trigger == NONE && !o->output_credit) || (o->channel && o->pending_size != 0)) return;
    unsigned char data[CHUNK];
    ssize_t n = read(o->output, data, sizeof(data));
    if (n > 0 && o->channel && (!o->stream || o->trigger == NONE || o->trigger == COMPLETED)) {
        packet(o, 'D', data, (size_t)n); o->output_credit = 0;
    }
    else if (n == 0) o->output_eof = 1;
    else if (n < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
        remember(o, OUTPUT, errno); o->output_eof = 1;
    }
}

static void child_exec(int input[2], int output[2], int gate[2], int errors[2], const char *shell, const char *command, char **direct) {
    if (setpgid(0, 0) < 0 || dup2(input[0], STDIN_FILENO) < 0 ||
        dup2(output[1], STDOUT_FILENO) < 0 || dup2(errors == NULL ? output[1] : errors[1], STDERR_FILENO) < 0) _exit(126);
    close(input[0]); close(input[1]); close(output[0]); close(output[1]); close(gate[1]);
    if (errors != NULL) { close(errors[0]); close(errors[1]); }
    char start = 0;
    ssize_t count;
    do { count = read(gate[0], &start, 1); } while (count < 0 && errno == EINTR);
    close(gate[0]);
    if (count != 1 || start != 'G') _exit(125);
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask);
    const int signals[] = {SIGTERM, SIGHUP, SIGINT, SIGPIPE};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) sigaction(signals[i], &action, NULL);
    if (direct != NULL) execv(direct[0], direct);
    else execl(shell, shell, "-lc", command, (char *)NULL);
    _exit(127);
}

int main(int argc, char **argv) {
    int stream = argc >= 4 && strcmp(argv[2], "--stream") == 0;
    int direct = stream || (argc >= 4 && strcmp(argv[2], "--argv") == 0);
    if ((!direct && argc != 4) || argc > 260) return 64;
    char *end;
    errno = 0; long budget = strtol(argv[1], &end, 10);
    if (errno || *end || budget <= 0 || (direct ? argv[3][0] : argv[2][0]) != '/') return 64;
    int64_t now = clock_ms(); if (now < 0 || budget > INT64_MAX - now - GRACE_MS - VERIFY_MS - 250) return 70;
    struct owner o;
    memset(&o, 0, sizeof(o));
    o.child = -1; o.input = -1; o.output = -1; o.gate = -1;
    o.status = -1; o.trigger = NONE; o.channel = 1; o.control_open = 1; o.deadline = now + budget;
    o.stream = stream; o.error_output = -1; o.error_eof = !stream;
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = stop_signal; sigemptyset(&action.sa_mask);
    const int signals[] = {SIGTERM, SIGHUP, SIGINT, SIGPIPE};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
        if (sigaction(signals[i], &action, NULL) < 0) return 70;
    if (sigprocmask(SIG_SETMASK, &action.sa_mask, NULL) < 0) return 70;
    action.sa_handler = SIG_DFL;
    if (sigaction(SIGCHLD, &action, NULL) < 0) return 70;
    int input[2], output[2], gate[2], errors[2];
    if (owned_pipe(input) < 0) return 70;
    if (owned_pipe(output) < 0) { close(input[0]); close(input[1]); return 70; }
    if (owned_pipe(gate) < 0) { close(input[0]); close(input[1]); close(output[0]); close(output[1]); return 70; }
    if (stream && owned_pipe(errors) < 0) return 70;
    if (stream && (nonblocking(errors[0]) < 0 || nonblocking(input[1]) < 0)) return 70;
    /* Configure polled fds before fork, so setup failure cannot block cleanup. */
    if (nonblocking(STDIN_FILENO) < 0 || nonblocking(STDOUT_FILENO) < 0 || nonblocking(output[0]) < 0) return 70;
    o.child = fork();
    if (o.child == 0) child_exec(input, output, gate, stream ? errors : NULL, argv[2], argv[3], direct ? &argv[3] : NULL);
    if (o.child < 0) return 70; /* No hook child exists; the OS closes our descriptors. */
    close(input[0]); close(output[1]); close(gate[0]);
    o.input = input[1]; o.output = output[0]; o.gate = gate[1];
    if (stream) { close(errors[1]); o.error_output = errors[0]; }
    if (setpgid(o.child, o.child) == 0 || getpgid(o.child) == o.child) o.grouped = 1;
    else { remember(&o, GROUP, errno); begin_stop(&o, FAILED, now); }
    char ready[96];
    int length = snprintf(ready, sizeof(ready), "%d %ld %ld", stream ? 2 : 1, (long)o.child, (long)getpid());
    packet(&o, 'R', ready, (size_t)length);

    for (;;) {
        now = clock_ms();
        if (now < 0) {
            /* No trustworthy clock: kill while identity is still retained; never claim closure. */
            signal_owned(&o, SIGKILL); return 70;
        }
        if (interrupted) begin_stop(&o, SIGNALLED, now);
        read_control(&o, now);
        observe_child(&o);
        if (o.seen_exit) begin_stop(&o, COMPLETED, now);
        if (now >= o.deadline) begin_stop(&o, DEADLINE, now);
        if (o.phase != NO_ERROR) begin_stop(&o, FAILED, now);
        complete_cleanup(&o, now);
        flush_input(&o, now);
        if (o.write_ack && o.pending_size == 0) {
            packet(&o, 'W', &o.write_id, 4); o.write_ack = 0;
        }
        if (o.stream && o.error_first) { read_error(&o); read_output(&o); }
        else { read_output(&o); read_error(&o); }
        o.error_first = !o.error_first;
        flush_packet(&o);
        if (!o.channel) begin_stop(&o, OWNER_GONE, now);

        int ended = o.trigger != NONE && o.confirmed && o.output_eof && o.error_eof;
        int expired = o.trigger != NONE && now >= o.finish_deadline;
        if (!o.final_queued && (ended || expired) && o.pending_size == 0 && !o.write_ack) {
            char result[160];
            int certain = o.grouped && o.reap_confirmed && o.confirmed &&
                          o.output_eof && o.error_eof && !o.closure_error;
            length = snprintf(result, sizeof(result), "%d %d %d %d %d %d %ld", stream ? 2 : 1, (int)o.trigger,
                              o.status, certain, (int)o.phase, o.reason, (long)o.child);
            if (!o.channel) return certain ? 0 : 70;
            packet(&o, 'F', result, (size_t)length); o.final_queued = 1;
        }
        if (o.final_queued && o.pending_size == 0) return 0;
        if (expired && now >= o.finish_deadline + 250) return 70;
        int readable_output = !o.stream || o.trigger != NONE || o.output_credit;
        struct pollfd fds[5] = {
            {o.control_open ? STDIN_FILENO : -1, POLLIN, 0},
            {o.output, o.output_eof || !readable_output || (o.channel && o.pending_size != 0) ? 0 : POLLIN, 0},
            {STDOUT_FILENO, o.channel && o.pending_size != 0 ? POLLOUT : 0, 0},
            {o.error_output, o.error_eof || !readable_output || (o.channel && o.pending_size != 0) ? 0 : POLLIN, 0},
            {o.input, o.input_size != 0 && o.trigger == NONE ? POLLOUT : 0, 0}
        };
        int result = poll(fds, 5, 10);
        if (result < 0 && errno != EINTR) { remember(&o, CONTROL, errno); begin_stop(&o, FAILED, now); }
    }
}
