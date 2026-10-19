// Nestcast.app launcher: a stable, signed-once executable that owns the
// macOS privacy permissions (System Audio Recording, Local Network) and runs
// the frequently-rebuilt nestcast binary as a child, which inherits them.
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
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
  // Run the bundled nestcast-core next to this launcher (NESTCAST_BIN, if
  // set, overrides it for development).
  char path[1024];
  char self[1024];
  uint32_t self_size = sizeof(self);
  path[0] = 0;
  if (_NSGetExecutablePath(self, &self_size) == 0) {
    char* slash = strrchr(self, '/');
    if (slash) {
      *slash = 0;
      snprintf(path, sizeof(path), "%s/nestcast-core", self);
      if (access(path, X_OK) != 0) path[0] = 0;
    }
  }
  const char* override_path = getenv("NESTCAST_BIN");
  if (override_path) snprintf(path, sizeof(path), "%s", override_path);
  if (!path[0]) {
    fprintf(stderr, "Nestcast launcher: nestcast-core not found\n");
    return 127;
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
