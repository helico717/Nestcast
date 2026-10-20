// Nestcast.app launcher: a stable executable that owns the macOS privacy
// permissions (System Audio Recording, Local Network) and runs the bundled
// nestcast-core as a child, which inherits them.
//
// Because the child inherits those permissions, the launcher only runs its
// own sibling binary, only if root owns it and nobody else can modify it
// (as installed by the .pkg into /Applications), and with DYLD_* variables
// removed. Both binaries are signed with the hardened runtime.
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <string.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <unistd.h>

extern char** environ;
static pid_t child = 0;

static void forward(int sig) {
  if (child > 0) kill(child, sig);
}

int main(int argc, char* argv[]) {
  char path[1024];
  char self[1024];
  uint32_t self_size = sizeof(self);
  if (_NSGetExecutablePath(self, &self_size) != 0) {
    return 127;
  }
  char* slash = strrchr(self, '/');
  if (!slash) {
    return 127;
  }
  *slash = 0;
  snprintf(path, sizeof(path), "%s/nestcast-core", self);
  // The binary and its directory must be root-owned and not writable by
  // group/others, so no unprivileged process can swap in its own code.
  struct stat st_file, st_dir;
  if (stat(path, &st_file) != 0 || stat(self, &st_dir) != 0 ||
      st_file.st_uid != 0 || st_dir.st_uid != 0 ||
      (st_file.st_mode & (S_IWGRP | S_IWOTH)) ||
      (st_dir.st_mode & (S_IWGRP | S_IWOTH))) {
    fprintf(stderr,
            "Nestcast launcher: refusing to run %s (must be root-owned and "
            "not writable by others; reinstall Nestcast)\n",
            path);
    return 126;
  }
  // No library injection into the process that holds the permissions.
  for (char** e = environ; *e;) {
    if (strncmp(*e, "DYLD_", 5) == 0) {
      char name[256];
      const char* eq = strchr(*e, '=');
      size_t n = eq ? (size_t)(eq - *e) : strlen(*e);
      if (n >= sizeof(name)) n = sizeof(name) - 1;
      memcpy(name, *e, n);
      name[n] = 0;
      unsetenv(name);  // Shifts the array; re-check the same slot.
    } else {
      ++e;
    }
  }
  argv[0] = path;
  signal(SIGINT, forward);
  signal(SIGTERM, forward);
  signal(SIGHUP, forward);
  int err = posix_spawn(&child, path, NULL, NULL, argv, environ);
  if (err) {
    fprintf(stderr, "Nestcast launcher: cannot start %s: %s\n", path,
            strerror(err));
    return 127;
  }
  int status = 0;
  while (waitpid(child, &status, 0) < 0) {
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
