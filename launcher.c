#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <string.h>
#include <limits.h>
#include <mach-o/dyld.h>

// Spawn the EqVol binary that lives next to this launcher, logging stderr.
// The app path is resolved relative to the launcher itself (not hardcoded),
// so the same binary works from ~/source/eqvol and from the installed
// location (/Library/Application Support/eqVol).
int main(void) {
  char self[PATH_MAX];
  char app[PATH_MAX];
  uint32_t sz = sizeof(self);
  if (_NSGetExecutablePath(self, &sz) != 0 || realpath(self, app) == NULL) {
    return 1;
  }
  char *slash = strrchr(app, '/');
  if (slash == NULL) return 1;
  memmove(slash + 1, "EqVol.app/Contents/MacOS/EqVol",
          sizeof("EqVol.app/Contents/MacOS/EqVol"));

  // Spawn the EqVol binary directly (unmanaged attribution), logging stderr.
  int log = open("/tmp/eqvol-agent.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
  int devnull = open("/dev/null", O_WRONLY);
  pid_t pid = fork();
  if (pid == 0) {
    dup2(devnull, STDOUT_FILENO);
    dup2(log, STDERR_FILENO);
    execl(app, "EqVol", (char*)NULL);
    _exit(127);
  }
  int status;
  waitpid(pid, &status, 0);   // stay alive: launchd kills the group otherwise
  return 0;
}
