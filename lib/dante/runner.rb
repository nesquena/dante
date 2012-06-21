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

    attr_accessor :options, :name, :description

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

      if options.include?(:kill)
        self.stop
      else # create process
        self.stop if options.include?(:restart)

        # If a username, uid, groupname, or gid is passed,
        # drop privileges accordingly.

        if options[:group]
          gid = options[:group].is_a?(Integer) ? options[:group] : Etc.getgrnam(options[:group]).gid
          Process::GID.change_privilege(gid)
        end

        if options[:user]
          uid = options[:user].is_a?(Integer) ? options[:user] : Etc.getpwnam(options[:user]).uid
          Process::UID.change_privilege(uid)
        end

        @startup_command = block if block_given?
        options[:daemonize] ? daemonize : start
      end
    end

    def daemonize
      return log("Process is already started") if self.daemon_running? # daemon already started

      # Start process
      pid = fork do
        exit if fork
        Process.setsid
        exit if fork
        store_pid(Process.pid)
        File.umask 0000
        redirect_output!
        start
      end
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

      trap("INT") {
        interrupt
        exit
      }
      trap("TERM"){
        interrupt
        exit
      }

      @startup_command.call(self.options) if @startup_command
    end

    # Stops a daemonized process
    def stop(kill_arg=nil)
      if self.daemon_running?
        kill_pid(kill_arg || options[:kill])
        until_true(MAX_START_TRIES) { self.daemon_stopped? }
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
      # begin
        raise Interrupt
        sleep(1)
      # rescue Interrupt
      #  log "Interrupt received; stopping #{@name}"
      # end
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
    rescue Errno::ESRCH
      false
    end

    protected

    def parse_options
      headline = [@name, @description].compact.join(" - ")
      OptionParser.new do |opts|
        opts.summary_width = 25
        opts.banner = [headline, "\n\n",
                     "Usage: #{@name} [-p port] [-P file] [-d] [-k]\n",
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

        opts.on("-l", "--log FILE", String, "Logfile for output") do |v|
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

        opts.on_tail("-?", "--help", "Display this usage information.") do
          puts "#{opts}\n"
          exit
        end

        # Load options specified through 'with_options'
        instance_exec(opts, &@with_options) if @with_options
      end.parse!
      options
    end

    def store_pid(pid)
      FileUtils.mkdir_p(File.dirname(options[:pid_path]))
      File.open(options[:pid_path], 'w'){|f| f.write("#{pid}\n")}
    end

    def kill_pid(k='*')
      Dir[options[:pid_path]].each do |f|
        begin
          pid = IO.read(f).chomp.to_i
          FileUtils.rm f
          Process.kill('INT', pid)
          log "Stopped PID: #{pid} at #{f}"
        rescue => e
          log "Failed to stop! #{k}: #{e}"
        end
      end
    end

    # Redirect output based on log settings (reopens stdout/stderr to specified logfile)
    # If log_path is nil, redirect to /dev/null to quiet output
    def redirect_output!
      if log_path = options[:log_path]
        FileUtils.touch log_path
        STDOUT.reopen(log_path, 'a')
        STDERR.reopen STDOUT
        File.chmod(0644, log_path)
        STDOUT.sync = true
      else # redirect to /dev/null
        STDIN.reopen "/dev/null"
        STDOUT.reopen "/dev/null", "a"
        STDERR.reopen STDOUT
      end
      log_path = options[:log_path] ? options[:log_path] : "/dev/null"
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
      puts message if options[:debug]
    end

  end
end
