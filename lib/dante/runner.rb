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

      # Start process
      pid = fork do
        exit if fork
        Process.setsid
        exit if fork
        # Handle INT and TERM before the pid file tells the caller we have started
        trap_signals
        store_pid(Process.pid)
        redirect_output!
        start
      end
      Process.waitpid pid
      # Ensure process is running
      if until_true(MAX_START_TRIES) { self.daemon_running? }
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
        kill_pid(kill_arg || options[:kill])
        
        if until_true(MAX_START_TRIES) { self.daemon_stopped? }
          FileUtils.rm options[:pid_path] # Only kill if we stopped the daemon
          log "Daemonized process killed after term."
        else
          log "Failed to kill daemonized process"
          if options[:force]
            kill_pid(kill_arg || options[:kill], 'KILL')

            if until_true(MAX_START_TRIES) { self.daemon_stopped? }
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
      Process.kill 0, File.read(options[:pid_path]).to_i
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

    # Switches the process to user (a name or uid) and group (a name or gid); the group
    # defaults to the user's primary group. Changing the uid and gid leaves the
    # supplementary groups as they were, so when running as root they are set too: to
    # the user's own groups, or to just the process's group for a group alone or a uid
    # with no passwd entry. Everything is looked up before anything is changed.
    def switch_user(user, group)
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
            elsif passwd
              passwd.gid
            end

      if Process.euid == 0
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

    def kill_pid(k='*', sig='TERM')
      Dir[options[:pid_path]].each do |f|
        begin
          pid = IO.read(f).chomp.to_i
          Process.kill(sig, pid)
          log "Sent SIG#{sig} to PID: #{pid} at #{f}"
        rescue => e
          log "Failed to stop! #{k}: #{e}"
        end
      end
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
