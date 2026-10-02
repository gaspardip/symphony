/* Trustee bootstrap: no candidate code runs before env/FD replacement.
 * argv: WORKSPACE_ROOT WORKSPACE HOME TMP PROFILE POLICY SHELL PATH -- [ARG...]
 * The host validates policy digest and generates the finite profile. */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int reject(int phase, int error, int cleanup) {
    fprintf(stderr, "boundary_error phase=%d errno=%d cleanup_errno=%d\n", phase, error, cleanup);
    return 78;
}
static bool within(const char *path, const char *root) {
    const size_t size = strlen(root);
    return strcmp(path, root) == 0 || (strncmp(path, root, size) == 0 && path[size] == '/');
}
static int physical(const char *path, bool directory, bool immutable) {
    char resolved[PATH_MAX];
    struct stat info;
    if (path[0] != '/' || strlen(path) >= sizeof(resolved)) return EINVAL;
    if (realpath(path, resolved) == NULL || lstat(path, &info) != 0) return errno;
    if (strcmp(path, resolved) != 0 || (directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode))) return EINVAL;
    if ((info.st_uid != geteuid() && info.st_uid != 0) || (info.st_mode & 0022) != 0) return EACCES;
    if (immutable && info.st_uid == geteuid() && (info.st_mode & 0222) != 0) return EACCES;
    return 0;
}
static int assignment(char *out, size_t capacity, const char *key, const char *value) {
    const int size = snprintf(out, capacity, "%s=%s", key, value);
    return size < 0 || (size_t)size >= capacity ? EOVERFLOW : 0;
}
int main(int argc, char **argv) {
    if (argc < 10 || argc > 256 || strcmp(argv[9], "--") != 0) return reject(1, EINVAL, 0);
    for (int i = 1; i <= 7; ++i) {
        const int error = physical(argv[i], i <= 4, i >= 5);
        if (error != 0) return reject(2, error, 0);
    }
    if (strcmp(argv[1], "/") == 0 || strcmp(argv[1], argv[2]) == 0 || !within(argv[2], argv[1])) return reject(3, EINVAL, 0);
    for (int i = 3; i <= 7; ++i) if (within(argv[i], argv[1])) return reject(3, EINVAL, 0);
    for (int i = 3; i <= 4; ++i) {
        for (int j = 3; j <= 7; ++j) {
            if (i != j && (within(argv[i], argv[j]) || within(argv[j], argv[i]))) return reject(3, EINVAL, 0);
        }
    }
    if (access(argv[7], X_OK) != 0) return reject(3, errno, 0);
    char path[16384], home[PATH_MAX + 8], tmp[PATH_MAX + 8];
    int error = assignment(path, sizeof(path), "PATH", argv[8]);
    if (error == 0) error = assignment(home, sizeof(home), "HOME", argv[3]);
    if (error == 0) error = assignment(tmp, sizeof(tmp), "TMPDIR", argv[4]);
    if (error != 0) return reject(4, error, 0);
    char *environment[] = {path, home, tmp, "LANG=C", "LC_ALL=C", NULL};
    char *command[260];
    size_t count = 0;
    command[count++] = "/usr/bin/sandbox-exec";
    command[count++] = "-f";
    command[count++] = argv[5];
    command[count++] = argv[7];
    for (int i = 10; i < argc; ++i) command[count++] = argv[i];
    command[count] = NULL;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    error = posix_spawn_file_actions_init(&actions);
    if (error != 0) return reject(5, error, 0);
    error = posix_spawnattr_init(&attributes);
    if (error != 0) return reject(6, error, posix_spawn_file_actions_destroy(&actions));
    int phase = 7;
    for (int fd = 0; fd <= 2 && error == 0; ++fd) error = posix_spawn_file_actions_addinherit_np(&actions, fd);
    if (error == 0) {
        phase = 8;
        error = posix_spawnattr_setflags(&attributes, (short)(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT));
    }
    if (error == 0) { phase = 9; if (chdir(argv[2]) != 0) error = errno; }
    if (error == 0) {
        phase = 10;
        error = posix_spawn(NULL, command[0], &actions, &attributes, command, environment);
        if (error == 0) error = EPROTO;
    }
    const int action_cleanup = posix_spawn_file_actions_destroy(&actions);
    const int attribute_cleanup = posix_spawnattr_destroy(&attributes);
    fprintf(stderr, "boundary_cleanup actions_errno=%d attributes_errno=%d\n", action_cleanup, attribute_cleanup);
    return reject(phase, error, action_cleanup != 0 ? action_cleanup : attribute_cleanup);
}
#else
/* Build remains available on Linux; selected macOS policy fails in Elixir before launch. */
#include <stdio.h>
int main(void) { fputs("boundary_error unsupported_platform\n", stderr); return 78; }
#endif
