// Strips NotProton's own DYLD_INSERT_LIBRARIES entry and the SDL block list from child processes
#include "hooks.h"
#include "../util/log.h"

#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int   DobbyHook(void *address, void *replace_call, void **origin_call);
extern void *DobbySymbolResolver(const char *image_name, const char *symbol_name);

typedef int (*fn_execve)(const char *path, char *const argv[], char *const envp[]);
typedef int (*fn_posix_spawn)(pid_t *pid, const char *path,
                             const posix_spawn_file_actions_t *fa,
                             const posix_spawnattr_t *attr,
                             char *const argv[], char *const envp[]);

static fn_execve      orig_execve;
static fn_posix_spawn orig_posix_spawn;
static fn_posix_spawn orig_posix_spawnp;

// The SDL block list stops Steam from seeing a second, generic copy of the Steam Controller.
// This solves double input issues.
static const char np_insert_key[] = "DYLD_INSERT_LIBRARIES=";

static const char *const np_steam_only_keys[] = {
    np_insert_key,
    "SDL_JOYSTICK_BLACKLIST_DEVICES=",
};

static int np_is_steam_only(const char *entry) {
    for (size_t k = 0; k < sizeof(np_steam_only_keys) / sizeof(np_steam_only_keys[0]); k++) {
        if (strncmp(entry, np_steam_only_keys[k], strlen(np_steam_only_keys[k])) == 0)
            return 1;
    }
    return 0;
}

// steam_osx re-execs itself and needs the insert for hooks. Steam Helper runs
// CEF and needs it for the webpatch fopen interpose, strips elsewhere
static int np_target_keeps_insert(const char *path) {
    if (!path)
        return 1;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcmp(base, "steam_osx") == 0
        || strcmp(base, "Steam Helper") == 0;
}

// NotProton's own entry in the insert list, matched by file name wherever it was deployed.
static int np_is_own_insert(const char *path, size_t len) {
    static const char own[] = "notproton.dylib";
    size_t n = sizeof(own) - 1;
    return len >= n && memcmp(path + len - n, own, n) == 0
        && (len == n || path[len - n - 1] == '/');
}

// Another tool can share Steam's insert with NotProton. Its libraries stay in the list for
// every child, and only NotProton's own entry is dropped. Writes the remaining list to `out`
// when it is not NULL, and returns its length, 0 when nothing is left.
static size_t np_others_in_insert(const char *list, char *out) {
    size_t used = 0;
    for (const char *p = list; ; ) {
        const char *end = strchr(p, ':');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len && !np_is_own_insert(p, len)) {
            if (out) {
                if (used)
                    out[used] = ':';
                memcpy(out + used + (used ? 1 : 0), p, len);
            }
            used += len + (used ? 1 : 0);
        }
        if (!end)
            break;
        p = end + 1;
    }
    if (out)
        out[used] = '\0';
    return used;
}

static int np_is_insert(const char *entry) {
    return strncmp(entry, np_insert_key, sizeof(np_insert_key) - 1) == 0;
}

// The array and any rewritten insert share one allocation, so freeing the array frees both.
static char **np_without_insert(char *const envp[]) {
    if (!envp)
        return NULL;

    int count = 0;
    int found = 0;
    size_t extra = 0;
    for (int i = 0; envp[i]; i++) {
        if (np_is_steam_only(envp[i]))
            found = 1;
        if (np_is_insert(envp[i])) {
            size_t others = np_others_in_insert(envp[i] + sizeof(np_insert_key) - 1, NULL);
            if (others)
                extra += sizeof(np_insert_key) - 1 + others + 1;
        }
        count++;
    }
    if (!found)
        return NULL;

    size_t table = sizeof(char *) * (size_t)(count + 1);
    char **clean = malloc(table + extra);
    if (!clean) {
        NP_WARN("[spawn] cannot allocate a stripped environment, insert passed through");
        return NULL;
    }

    char *store = (char *)clean + table;
    int j = 0;
    for (int i = 0; envp[i]; i++) {
        if (np_is_insert(envp[i])) {
            const char *list = envp[i] + sizeof(np_insert_key) - 1;
            if (!np_others_in_insert(list, NULL))
                continue;
            memcpy(store, np_insert_key, sizeof(np_insert_key) - 1);
            size_t others = np_others_in_insert(list, store + sizeof(np_insert_key) - 1);
            clean[j++] = store;
            store += sizeof(np_insert_key) - 1 + others + 1;
        } else if (!np_is_steam_only(envp[i])) {
            clean[j++] = envp[i];
        }
    }
    clean[j] = NULL;
    return clean;
}

static int np_hook_execve(const char *path, char *const argv[], char *const envp[]) {
    if (np_target_keeps_insert(path))
        return orig_execve(path, argv, envp);

    char **clean = np_without_insert(envp);
    if (!clean)
        return orig_execve(path, argv, envp);

    NP_DBG("[spawn] execve '%s' without the insert", path);
    int rc = orig_execve(path, argv, (char *const *)clean);
    // Only reached when the exec failed, since a successful one replaced this image.
    free(clean);
    return rc;
}

static int np_spawn_without_insert(fn_posix_spawn orig, const char *api,
                                   pid_t *pid, const char *path,
                                   const posix_spawn_file_actions_t *fa,
                                   const posix_spawnattr_t *attr,
                                   char *const argv[], char *const envp[]) {
    if (np_target_keeps_insert(path))
        return orig(pid, path, fa, attr, argv, envp);

    char **clean = np_without_insert(envp);
    if (!clean)
        return orig(pid, path, fa, attr, argv, envp);

    NP_DBG("[spawn] %s '%s' without the insert", api, path);
    int rc = orig(pid, path, fa, attr, argv, (char *const *)clean);
    free(clean);
    return rc;
}

static int np_hook_posix_spawn(pid_t *pid, const char *path,
                               const posix_spawn_file_actions_t *fa,
                               const posix_spawnattr_t *attr,
                               char *const argv[], char *const envp[]) {
    return np_spawn_without_insert(orig_posix_spawn, "posix_spawn",
                                   pid, path, fa, attr, argv, envp);
}

static int np_hook_posix_spawnp(pid_t *pid, const char *path,
                                const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr,
                                char *const argv[], char *const envp[]) {
    return np_spawn_without_insert(orig_posix_spawnp, "posix_spawnp",
                                   pid, path, fa, attr, argv, envp);
}

static void np_hook_symbol(const char *sym, void *repl, void **orig) {
    void *addr = DobbySymbolResolver("libsystem_kernel.dylib", sym);
    if (!addr)
        addr = DobbySymbolResolver(NULL, sym);
    if (!addr) {
        NP_WARN("[spawn] %s: unresolved, children keep the insert", sym);
        return;
    }

    int rc = DobbyHook(addr, repl, orig);
    if (rc == 0)
        NP_LOG("[spawn] %s: hooked @ %p", sym, addr);
    else
        NP_WARN("[spawn] %s: DobbyHook failed rc=%d, children keep the insert", sym, rc);
}

void np_hooks_spawn_install(void) {
    if (np_hooks_env_lists_label("NOTPROTON_DISABLE", "spawn")) {
        NP_WARN("[spawn] DISABLED via NOTPROTON_DISABLE, children keep the insert");
        return;
    }

    np_hook_symbol("execve",       (void *)np_hook_execve,       (void **)&orig_execve);
    np_hook_symbol("posix_spawn",  (void *)np_hook_posix_spawn,  (void **)&orig_posix_spawn);
    np_hook_symbol("posix_spawnp", (void *)np_hook_posix_spawnp, (void **)&orig_posix_spawnp);
}
