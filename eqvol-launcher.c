#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
int main(void) {
  // Spawn the EqVol binary directly (unmanaged attribution), logging stderr.
  int log = open("/tmp/eqvol-agent.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
  int devnull = open("/dev/null", O_WRONLY);
  pid_t pid = fork();
  if (pid == 0) {
    dup2(devnull, STDOUT_FILENO);
    dup2(log, STDERR_FILENO);
    setenv("EQVOL_STATS", "1", 1);
    execl("/Users/jeff/source/eqvol/EqVol.app/Contents/MacOS/EqVol",
          "EqVol", (char*)NULL);
    _exit(127);
  }
  int status;
  waitpid(pid, &status, 0);   // stay alive: launchd kills the group otherwise
  return 0;
}
