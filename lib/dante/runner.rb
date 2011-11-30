require 'fileutils'
require 'optparse'
require 'yaml'
require 'erb'

=begin

This is a utility for setting up a binary executable for a service.

# Dante::Runner.new("buffet", :pid_path => "/var/run/buffet.pid") do
#   ...startup service here...
# end

=end

module Dante
  class Runner
    # Signal to application that the process is shutting down
    class Abort < Exception; end

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
        :pid_path => "/var/run/#{@name}.pid"
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
    def execute(&block)
      parse_options

      if options.include?(:kill)
        kill_pid(options[:kill] || '*')
      else # create process
        Process.euid = options[:user] if options[:user]
        Process.egid = options[:group] if options[:group]
        @startup_command = block if block_given?
        options[:daemonize] ? daemonize : start
      end
    end

    def start
      puts "Starting #{@name} service..."

      trap("INT") {
        stop
        exit
      }
      trap("TERM"){
        stop
        exit
      }

      @startup_command.call(self.options) if @startup_command
    end

    def stop
      raise Abort
      sleep(1)
    end

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

    private

    def store_pid(pid)
     FileUtils.mkdir_p(File.dirname(options[:pid_path]))
     File.open(options[:pid_path], 'w'){|f| f.write("#{pid}\n")}
    end

    def kill_pid(k)
      Dir[options[:pid_path]].each do |f|
        begin
          pid = IO.read(f).chomp.to_i
          FileUtils.rm f
          Process.kill(9, pid)
          puts "killed PID: #{pid} at #{f}"
        rescue => e
          puts "Failed to kill! #{k}: #{e}"
        end
      end
    end

    def daemonize
      pid = fork do
        exit if fork
        Process.setsid
        exit if fork
        store_pid(Process.pid)
        File.umask 0000
        STDIN.reopen "/dev/null"
        STDOUT.reopen "/dev/null", "a"
        STDERR.reopen STDOUT
        start
      end
    end

  end
end