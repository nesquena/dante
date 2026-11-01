# Changelog

## Unreleased

- Fixed: a daemon's standard input is now `/dev/null`. It stayed on the terminal or pipe it was started from, so a
  daemon reading stdin read the user's keystrokes, and a terminal or pty that started it never saw end-of-file
  while the daemon ran. (#XXXX, @nesquena)

## 0.3.0 (2026-10-31)

Changes since 0.2.0:

- **Ruby 2.7 or newer is now required** (the gemspec declares it). Stay on 0.2.0 for older Rubies. (#21, @nesquena)
- **New `-f`/`--force` option** (`:force => true`): when a stop's SIGTERM does not stop the daemon within 5 seconds,
  dante sends SIGKILL. (#13, @hayesgm)
- **Changed: stopping keeps the pid file until the daemon has stopped.** `-k`/`stop` used to delete the pid file
  before signalling; it now deletes it only once the daemon has exited, and keeps it (and says "Failed to kill
  daemonized process") when the daemon survives. The log line is now "Sent SIGTERM to PID: ..." instead of
  "Stopped PID: ...": update anything that matches the old text. (#13, @hayesgm)
- **Changed: user and group switching as root** (`-u`, `-G`, `:user`, `:group`). Everything is looked up before
  anything changes. `-u` now takes the user's primary group (or the `-G` group) and the user's own supplementary
  groups; before, the daemon kept gid 0 and root's supplementary groups. `-G` alone leaves only that group. If your
  daemon relied on root's groups, add the user to the groups it needs or pass `-G`. Where root may not change its
  groups (a restricted capability set, or a user namespace that denies setgroups), `-u` now fails at startup with
  `Errno::EPERM`, as `su` does. A non-root process changes only what it was given, as before. (#22, @nesquena)
- **Changed: the daemon keeps the caller's umask** instead of setting it to 0000, so new files are 644 and
  directories 755 under umask 022 (they were 666 and 777). If the daemon must create world-writable files, set
  `File.umask` in the startup block. The log file stays 0644. (#22, @nesquena)
- **Changed: a daemon now counts as started only if it is still running 1 second after it was forked**, so
  `-d` takes up to a second longer. A daemon that exits at once (its startup block raised, or returned) is now
  reported as "Daemonized process couldn't be started", `daemonize` returns false, and the pid file it left is
  removed; before, it could be reported as started, and its stale pid stayed in the pid file. The exit status of
  your executable doesn't change (dante doesn't set it): to act on a failed start, check what `execute` returns.
  (#24, @nesquena)
- **Changed: the process between the caller and the daemon no longer runs the program's `at_exit` handlers**; it
  leaves with `exit!`, as Ruby's `Process.daemon` does. They used to run in the two intermediate processes right
  after the fork, so a cleanup handler (stripe-ruby-mock's `kill_server`, say) ran there too. Handlers still run in
  the caller and in the daemon; nothing to do unless you relied on that extra run. (#24, @nesquena)
- Fixed: output redirection when the standard streams are sockets (Spring, Zeus): output now goes to the log
  instead of raising `can't change access mode`. Reported by @antonfefilov in #20. (#22, @nesquena)
- Fixed: a pid file naming another user's process no longer crashes with `Errno::EPERM`: starting prints "Process
  is already started", and `-k` reports that it could not stop the process and keeps the pid file. (#22, @nesquena)
- Fixed: `-k` on another user's process gives up at once (in about 0.2 seconds) instead of waiting 5 seconds, or
  10 with `--force`, for a process it cannot signal. (#24, @nesquena)
- Fixed: an empty pid file (left by a crash between creating and writing it), or one holding 0 or a negative
  number, counts as no daemon. Before, starting refused with "Process is already started", and `-k` sent SIGTERM
  to its own process group, killing itself and the processes started alongside it. A number too large for a pid
  counts as no daemon too, where it raised `RangeError`. (#24, @nesquena)
- Fixed: daemonizing from a program that ignores SIGCHLD (`trap('CHLD', 'IGNORE')`) raised `Errno::ECHILD`; it now
  reports whether the daemon started. (#24, @nesquena)
- Fixed: INT and TERM are handled before the pid file is written, so a `-k` right after start goes through
  dante's handler. (#22, @nesquena)
- The gemspec now declares the MIT license and points its homepage at github.com/nesquena/dante, and the
  deprecated `rubyforge_project` setting is gone. (#27, @nesquena)
- Development: the test suite is reliable on current Ruby and minitest (mocha is no longer needed), `rake` runs
  it, and GitHub Actions runs it on Ruby 2.7 to 4.0. Reported by @balasankarc in #19. (#21, #23, @nesquena)

## 0.2.0 (2013-12-04)

- A `verify_options_hook` to validate options; daemon mode logs to `/var/log/<name>.log` by default; a log file
  given in the foreground is used. (#7, #9, #10, @rkatti)
- The daemonizing process reaps its child, leaving no zombie. (#5, @jonigata)

## 0.1.5 (2012-06-21)

- Fixes for `kill_pid`, `interrupt` and `log`. (@mckern)

## 0.1.4 (2012-06-20)

- Fixed user and group switching and log redirection; cleaner shutdown message. (#1, @mckern)

## 0.1.3 (2012-01-30)

- `-l`/`--log`: a log file for the daemon's output.

## 0.1.2 (2011-12-06)

- `daemon_running?` and `daemon_stopped?` are public.

## 0.1.1 (2011-12-06)

- Better handling of the debug option.

## 0.1.0 (2011-12-06)

- A more robust runner: stops and starts are checked, and `restart` is added.

## 0.0.4 (2011-11-30)

- Stopping sends INT instead of KILL. (@joshbuddy)

## 0.0.3 (2011-11-30)

- Cleaner process stopping.

## 0.0.2 (2011-11-28)

- Custom options (`with_options`), a custom banner, and options passed to the startup block.

## 0.0.1 (2011-11-21)

- First release.
