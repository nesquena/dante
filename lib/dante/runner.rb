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

      if options.include?(:kill)
        self.stop
      else # create process
        self.stop if options.include?(:restart)

        # If a username, uid, groupname, or gid is passed,
        # drop privileges accordingly.
        switch_user(options[:user], options[:group]) if options[:user] || options[:group]

        @startup_command = block if block_given?
        options[:daemonize] ? daemonize : start
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
      started = begin
        Process.waitpid2(pid)[1].success?
      rescue Errno::ECHILD # SIGCHLD is ignored, so the session leader's status is lost: go by the pid file
        true
      end
      # Ensure process is running
      if started && until_true(MAX_START_TRIES) { self.daemon_running? }
        log "Daemon has started successfully"
        true
      else # Failed to start
        log "Daemonized process couldn't be started"
        false
      end
    end

    def start
      log "Starting #{@name} service..."

      if log_path = options[:log_path] && options[:daemonize].nil?
         redirect_output! 
      end

      trap_signals

      @startup_command.call(self.options) if @startup_command
    end

    # Stops a daemonized process
    def stop(kill_arg=nil)
      if self.daemon_running?
        if wait_for_stop(kill_pid(kill_arg || options[:kill]))
          FileUtils.rm options[:pid_path] # Only kill if we stopped the daemon
          log "Daemonized process killed after term."
        else
          log "Failed to kill daemonized process"
          if options[:force]
            if wait_for_stop(kill_pid(kill_arg || options[:kill], 'KILL'))
              FileUtils.rm options[:pid_path] # Only kill if we stopped the daemon
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
      self.start
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

    # Returns running for the daemonized process
    # self.daemon_running?
    def daemon_running?
      return false unless File.exist?(options[:pid_path])
      return false unless pid = read_pid(options[:pid_path])
      Process.kill 0, pid
      true
    rescue Errno::EPERM # the process exists but belongs to another user
      true
    rescue Errno::ESRCH
      false
    end

    protected

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

        opts.on("-k", "--kill [PORT]", String, "Kill specified running daemons - leave blank to kill all.") do |v|
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

    def store_pid(pid)
      FileUtils.mkdir_p(File.dirname(options[:pid_path]))
      File.open(options[:pid_path], 'w'){|f| f.write("#{pid}\n")}
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
    def remove_pid_file(pid)
      File.delete(options[:pid_path]) if read_pid(options[:pid_path]) == pid
    rescue Errno::ENOENT
    end

    # The pid in pid_file, or nil when it holds none: a pid file left empty by a crash
    # between creating and writing it names no process (and pid 0 or a negative pid would
    # signal a whole process group).
    def read_pid(pid_file)
      pid = File.read(pid_file).to_i
      pid if pid > 0
    end

    # Sends sig to the daemons, and returns whether it reached any of them.
    def kill_pid(k='*', sig='TERM')
      Dir[options[:pid_path]].count do |f|
        begin
          next false unless pid = read_pid(f)
          Process.kill(sig, pid)
          log "Sent SIG#{sig} to PID: #{pid} at #{f}"
          true
        rescue => e
          log "Failed to stop! #{k}: #{e}"
          false
        end
      end > 0
    end

    # Waits for the daemon to stop once a signal reached it. When none did (the daemon
    # belongs to another user), it cannot stop, so this only checks once.
    def wait_for_stop(signalled)
      signalled ? until_true(MAX_START_TRIES) { self.daemon_stopped? } : self.daemon_stopped?
    end

    # Redirect output based on log settings (reopens stdout/stderr to specified logfile)
    # If log_path is nil, redirect to /dev/null to quiet output
    def redirect_output!
      if log_path = options[:log_path]
        # if the log directory doesn't exist, create it
        FileUtils.mkdir_p File.dirname(options[:log_path]), :mode => 0755
        # touch the log file to create it
        FileUtils.touch log_path
        # Set permissions on the log file
        File.chmod(0644, log_path)
        # Reopen $stdout (NOT +STDOUT+) to start writing to the log file
        reopen_stream($stdout, log_path, 'a')
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

    # Reopens stream onto path, opened with mode. Reopening onto an open File rather
    # than a path works whatever mode the stream itself was opened with (a socket, for
    # one, when run under Spring or Zeus).
    def reopen_stream(stream, path, mode)
      File.open(path, mode) { |file| stream.reopen(file) }
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
