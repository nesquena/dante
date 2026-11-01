require 'fileutils'
require 'optparse'
require 'yaml'
require 'erb'
require 'etc'

=begin

This is a utility for setting up a binary executable for a service.

# Dante::Runner.new("buffet", :pid_path => "/var/run/buffet.pid") do
#   ...startup service here...
# end

=end

module Dante
  class Runner
    MAX_START_TRIES = 5
    # Seconds a new daemon must stay up before it counts as started.
    # ceiling: a daemon that dies later than this is still reported as started; a
    # readiness signal from the startup block would close that.
    START_GRACE = 1

    attr_accessor :options, :name, :description, :verify_options_hook

    class << self
      def run(*args, &block)
        self.new(*args, &block)
      end
    end

    def initialize(name, defaults={}, &block)
      @name = name
      @startup_command = block
      @options = {
        :host => '0.0.0.0',
        :pid_path => "/var/run/#{@name}.pid",
        :log_path => false,
        :debug => true
      }.merge(defaults)
    end

    # Accepts options for the process
    # @runner.with_options { |opts| opts.on(...) }
    def with_options(&block)
      @with_options = block
    end

    # Executes the runner based on options
    # @runner.execute
    # @runner.execute { ... }
    def execute(opts={}, &block)
      parse_options
      self.options.merge!(opts)

      @verify_options_hook.call(self.options) if @verify_options_hook

      # A key given as false is off; -k with no argument sets :kill to nil, which is on.
      if options.fetch(:kill, false) != false
        self.stop
      else # create process
        self.stop if options.fetch(:restart, false) != false

        # If a username, uid, groupname, or gid is passed,
        # drop privileges accordingly.
        switch_user(options[:user], options[:group]) if options[:user] || options[:group]

        @startup_command = block if block_given?
        start_service
      end
    end

    def daemonize
      return log("Process is already started") if self.daemon_running? # daemon already started

      if !options[:log_path]
         options[:log_path] = "/var/log/#{@name}.log"
      end

      # Start process: a session leader forks the daemon, then exits with success only
      # if the daemon is still running START_GRACE seconds later. As the daemon's parent
      # it sees the daemon exit at once, where the pid file cannot tell.
      pid = fork do
        started = false
        begin
          Process.setsid
          daemon = fork do
            # Handle INT and TERM before the pid file tells the caller we have started
            trap_signals
            store_pid(Process.pid)
            redirect_output!
            reopen_stream(IO.for_fd(0, autoclose: false), File::NULL, 'r') # fd 0, whatever STDIN or $stdin is
            start
          end
          started = daemon_survives?(daemon)
          remove_pid_file(daemon) unless started # the pid of a daemon that is gone
        rescue Exception => e
          warn "#{e.class}: #{e.message}"
        ensure
          # Like Process.daemon, leave without running the at_exit handlers inherited
          # from the caller: they are the caller's, and one that exits or raises would
          # replace this exit status.
          exit!(started)
        end
      end
      waited = false
      started = begin
        survived = Process.waitpid2(pid)[1].success?
        waited = true
        # Ensure process is running
        survived && until_true(MAX_START_TRIES) { self.daemon_running? }
      rescue Errno::ECHILD
        # SIGCHLD is ignored, so the session leader's status is lost. It has exited, though,
        # removing the pid file of a daemon that died, so one look at the pid file tells.
        waited = true
        self.daemon_running?
      ensure
        # Interrupted while the session leader runs: reap it in the background, or it
        # lingers as a zombie.
        Process.detach(pid) unless waited
      end
      if started
        log "Daemon has started successfully"
        true
      else # Failed to start
        log "Daemonized process couldn't be started"
        false
      end
    end

    def start
      log "Starting #{@name} service..."

      # A daemon has redirected its output already
      redirect_output! if options[:log_path] && !options[:daemonize]

      trap_signals

      @startup_command.call(self.options) if @startup_command
    end

    # Stops a daemonized process. The pid file is read once: the daemon it names then is
    # the one signalled and waited for, whatever the pid file says by the time it stops.
    def stop(kill_arg=nil)
      pid, pid_file_stat = read_pid_file(options[:pid_path])
      running = pid && process_running?(pid)
      if running && (untrusted = untrusted_pid_file(pid, pid_file_stat))
        log "#{untrusted}; not stopping it"
        false
      elsif running
        if wait_for_stop(pid, kill_pid(pid, kill_arg || options[:kill]))
          remove_pid_file(pid) # Only once the daemon has stopped
          log "Daemonized process killed after term."
        else
          log "Failed to kill daemonized process"
          if options[:force]
            if wait_for_stop(pid, kill_pid(pid, kill_arg || options[:kill], 'KILL'))
              remove_pid_file(pid) # Only once the daemon has stopped
              log "Daemonized process killed after kill."
            end
          end
        end
      else # not running
        log "No #{@name} processes are running"
        false
      end
    end

    def restart
      self.stop
      start_service
    end

    def interrupt
      if options[:debug]
        raise Interrupt
        sleep 1
      else
        log "Interrupt received; stopping #{@name}"
      end
    end

    # Returns true if process is not running
    def daemon_stopped?
      ! self.daemon_running?
    end

    # Returns running for the daemonized process. A pid file that another user could have
    # written (see untrusted_pid_file) names no daemon.
    # self.daemon_running?
    def daemon_running?
      pid, pid_file_stat = read_pid_file(options[:pid_path])
      return false unless pid
      process_running?(pid) && !untrusted_pid_file(pid, pid_file_stat)
    end

    protected

    # Starts the service: as a daemon with :daemonize, else in the foreground.
    def start_service
      options[:daemonize] ? daemonize : start
    end

    def parse_options
      headline = [@name, @description].compact.join(" - ")
      OptionParser.new do |opts|
        opts.summary_width = 25
        opts.banner = [headline, "\n\n",
                     "Usage: #{@name} [-p port] [-P file] [-d] [-k] [-f]\n",
                     "       #{@name} --help\n"].compact.join("")
        opts.separator ""

        opts.on("-p", "--port PORT", Integer, "Specify port", "(default: #{options[:port]})") do |v|
          options[:port] = v
        end

        opts.on("-P", "--pid FILE", String, "save PID in FILE when using -d option.", "(default: #{options[:pid_path]})") do |v|
          options[:pid_path] = File.expand_path(v)
        end

        opts.on("-d", "--daemon", "Daemonize mode") do |v|
          options[:daemonize] = v
        end

        opts.on("-l", "--log FILE", String, "Logfile for output", "(default: /var/log/#{@name}.log)") do |v|
          options[:log_path] = v
        end

        opts.on("-k", "--kill [PORT]", String, "Stop the daemon in the pid file (PORT is ignored)") do |v|
          options[:kill] = v
        end

        opts.on("-u", "--user USER", String, "User to run as") do |user|
          options[:user] = user
        end

        opts.on("-G", "--group GROUP", String, "Group to run as") do |group|
          options[:group] = group
        end

        opts.on("-f", "--force", String, "Force kill if SIGTERM fails") do |v|
          options[:force] = true
        end

        opts.on_tail("-?", "--help", "Display this usage information.") do
          puts "#{opts}\n"
          exit
        end
        
        # Load options specified through 'with_options'
        instance_exec(opts, &@with_options) if @with_options
      end.parse!
      options
    end

    # Switches the process to user (a name or uid) and group (a name or gid). When running
    # as root the group defaults to the user's primary group, and the supplementary groups
    # (which changing the uid and gid leaves as they were) are set too: to the user's own
    # groups, or to just the process's group for a group alone or a uid with no passwd
    # entry. Otherwise only what was given changes. Everything is looked up before
    # anything is changed.
    def switch_user(user, group)
      root = Process.euid == 0
      passwd = if user.is_a?(Integer)
                 begin
                   Etc.getpwuid(user)
                 rescue ArgumentError # a uid with no passwd entry
                   nil
                 end
               elsif user
                 Etc.getpwnam(user)
               end
      uid = passwd ? passwd.uid : user
      gid = if group
              group.is_a?(Integer) ? group : Etc.getgrnam(group).gid
            elsif passwd && root
              passwd.gid
            end

      if root
        if passwd
          Process.initgroups(passwd.name, gid)
        else
          Process.groups = [gid || Process.egid]
        end
      end
      Process::GID.change_privilege(gid) if gid
      Process::UID.change_privilege(uid) if uid
    end

    def trap_signals
      trap("INT") {
        interrupt
        exit
      }

      trap("TERM"){
        log "Trying to stop #{@name}..."
        exit
      }
    end

    # Writes pid to a new file in the pid file's directory and renames it into place, so
    # that whatever was at the pid file's path (a symlink, or another file) is replaced
    # rather than written into, and a reader sees either the old pid file or the whole new
    # one. In a directory the daemon cannot write, it writes the pid file there already.
    def store_pid(pid)
      pid_path = options[:pid_path]
      FileUtils.mkdir_p(File.dirname(pid_path))
      tmp_path = "#{pid_path}.#{pid}.tmp"
      FileUtils.rm_f(tmp_path) # one left by a crash (a symlink is removed, not followed)
      begin
        # EXCL: never written through a file or symlink put there since
        File.open(tmp_path, File::WRONLY | File::CREAT | File::EXCL) { |f| f.write("#{pid}\n") }
      rescue Errno::EACCES
        # A pid file made for the daemon's user in a directory it cannot write, as an init
        # script might. Without CREAT, a missing one fails, as it did before.
        # ceiling: not atomic, so a reader can see it half-written; giving the daemon's user
        # the directory restores the rename.
        tmp_path = nil
        File.open(pid_path, File::WRONLY | File::TRUNC | File::NOFOLLOW) { |f| f.write("#{pid}\n") }
        return
      end
      File.rename(tmp_path, pid_path)
    ensure
      FileUtils.rm_f(tmp_path) if tmp_path # left only when writing or renaming failed
    end

    # Whether daemon, a child of this process, is still running START_GRACE seconds after
    # it was forked. When the caller's SIGCHLD handling reaps children itself (SIGCHLD
    # ignored, or a handler that waits for them), waitpid cannot see the daemon, and
    # signal 0 at the end of the grace period tells instead.
    def daemon_survives?(daemon)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_GRACE
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        return false if Process.waitpid(daemon, Process::WNOHANG)
        sleep 0.1
      end
      true
    rescue Errno::ECHILD
      sleep [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
      begin
        Process.kill(0, daemon)
        true
      rescue Errno::ESRCH
        false
      end
    end

    # Removes the pid file if it still holds pid (another start may have replaced it).
    # ceiling: the read and the delete are two steps, so a daemon that writes its pid between them loses its
    # pid file; a lock on the pid file (flock) would close that window
    def remove_pid_file(pid)
      File.delete(options[:pid_path]) if read_pid(options[:pid_path]) == pid
    rescue Errno::ENOENT
    end

    # The pid in pid_file, or nil when there is none: no pid file, or one left empty by a
    # crash between creating and writing it, names no process (and pid 0 or a negative pid
    # would signal a whole process group), nor does a number too large for a pid_t.
    def read_pid(pid_file)
      read_pid_file(pid_file)&.first
    end

    # The pid in pid_file, as read_pid gives it, and the pid file's File::Stat, both from
    # the one file opened; nil without a pid. A symlink is not followed, and names no pid
    # (a start replaces it).
    def read_pid_file(pid_file)
      return unless File.exist?(pid_file)
      File.open(pid_file, File::RDONLY | File::NOFOLLOW) do |file|
        pid = file.read.to_i
        [pid, file.stat] if pid > 0 && pid < 2**31
      end
    rescue Errno::ENOENT, Errno::ELOOP # removed since the check, or a symlink
    end

    # Why the pid file, with File::Stat pid_file_stat, cannot be trusted to name pid, its
    # daemon: it has other hard links (which keep the owner of the file they link to), or
    # it is owned by neither root, nor a user that pid runs as (any of its uids), nor the
    # user running this (whose own permissions are all a stop could use), so another user
    # could have written it to have that process stopped. nil when it can be trusted, or
    # when the owner of pid cannot be told (it has gone, say).
    # ceiling: the owner of a process is read from /proc (Linux); elsewhere only the hard
    # links are checked. `ps -o ruid=,uid= -p PID` would tell the owner on other Unixes.
    def untrusted_pid_file(pid, pid_file_stat)
      return "pid file #{options[:pid_path]} has other hard links" if pid_file_stat.nlink > 1
      pid_file_uid = pid_file_stat.uid
      return if pid_file_uid == 0 || pid_file_uid == Process.euid
      uids = File.read("/proc/#{pid}/status")[/^Uid:(.*)$/, 1] or return # no Uid line
      process_uids = uids.split.map { |uid| Integer(uid) } # real, effective, saved, filesystem
      return if process_uids.include?(pid_file_uid)
      "pid file #{options[:pid_path]} is owned by uid #{pid_file_uid} but process #{pid} belongs to uid #{process_uids.first}"
    rescue SystemCallError # no /proc
    end

    # Whether pid is a running process, counting one that belongs to another user.
    def process_running?(pid)
      Process.kill 0, pid
      true
    rescue Errno::EPERM # the process exists but belongs to another user
      true
    rescue Errno::ESRCH
      false
    end

    # Sends sig to pid, the daemon, and returns whether it reached it.
    def kill_pid(pid, k, sig='TERM')
      Process.kill(sig, pid)
      log "Sent SIG#{sig} to PID: #{pid} at #{options[:pid_path]}"
      true
    rescue => e
      log "Failed to stop! #{k}: #{e}"
      false
    end

    # Waits for pid, the daemon, to stop once a signal reached it, checking every 0.1
    # seconds (a Rational step, so the steps add up to exactly MAX_START_TRIES seconds).
    # When no signal reached it (the daemon belongs to another user), it cannot stop, so
    # this only checks once.
    def wait_for_stop(pid, signalled)
      signalled ? until_true(MAX_START_TRIES, Rational(1, 10)) { !process_running?(pid) } : !process_running?(pid)
    end

    # Redirect output based on log settings (reopens stdout/stderr to specified logfile)
    # If log_path is nil, redirect to /dev/null to quiet output
    def redirect_output!
      if log_path = options[:log_path]
        # if the log directory doesn't exist, create it
        FileUtils.mkdir_p File.dirname(options[:log_path]), :mode => 0755
        # Reopen $stdout (NOT +STDOUT+) to append to the log file, created with mode 0644
        # (less the umask) if absent. An existing log file keeps its mode; a symlink is
        # followed.
        reopen_stream($stdout, log_path, 'a', 0644)
        # Redirect $stderr to $stdout
        $stderr.reopen $stdout
        $stdout.sync = true
      else # redirect to /dev/null
        # We're not bothering to sync if we're dumping to /dev/null
        # because /dev/null doesn't care about buffered output
        reopen_stream($stdin, '/dev/null', 'r')
        reopen_stream($stdout, '/dev/null', 'a')
        $stderr.reopen $stdout
      end
      log_path = options[:log_path] ? options[:log_path] : '/dev/null'
    end

    # Reopens stream onto path, opened with mode (and created with perm). Reopening onto
    # an open File rather than a path works whatever mode the stream itself was opened
    # with (a socket, for one, when run under Spring or Zeus).
    def reopen_stream(stream, path, mode, perm=0666)
      File.open(path, mode, perm) { |file| stream.reopen(file) }
    end

    # Runs until the block condition is met or the timeout_seconds is exceeded
    # until_true(10) { ...return_condition... }
    def until_true(timeout_seconds, interval=1, &block)
      elapsed_seconds = 0
      while elapsed_seconds < timeout_seconds && block.call != true
        elapsed_seconds += interval
        sleep(interval)
      end
      elapsed_seconds < timeout_seconds
    end

    def log(message)
      puts message
    end

  end
end
