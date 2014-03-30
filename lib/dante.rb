require "fileutils"
require "optparse"
require "logger"
require "astruct"

# The main class for running things
class Dante
  DEFAULT_LOGGER_CLASS = Logger
  DEFAULT_LOGGER_PATH = STDOUT
  DEFAULT_LOGGER_ROTATION = "daily"
  DEFAULT_PARAMETERS = lambda do
    Command.new do |command|
      command.on("--dlog_path PATH", String, "The log file path") do |log|
        options.log_path = log
      end

      command.on("--dpid_path PATH", String, "The CLI pid file path") do |pid|
        options.dpid_path = pid
      end

      command.on("--duser USER", String, "User to run the as") do |user|
        options.duser = user
      end

      command.on("--dgroup GROUP", String, "Group to run as") do |group|
        options.dgroup = group
      end

      command.on("--daemon", "If the process should daemonize") do
        options.daemon = true
      end
    end
  end

  def self.log_path=(path = DEFAULT_LOGGER_PATH)
    @log_path = path || DEFAULT_LOGGER_PATH
  end

  def self.log_path
    @log_path || DEFAULT_LOGGER_PATH
  end

  def self.log_rotation=(rotation = DEFAULT_LOGGER_ROTATION)
    @log_rotation = rotation || DEFAULT_LOGGER_ROTATION
  end

  def self.log_rotation
    @log_rotation || DEFAULT_LOGGER_ROTATION
  end

  def self.log_class=(klass = DEFAULT_LOGGER_CLASS)
    @log_class = klass || DEFAULT_LOGGER_CLASS
  end

  def self.log_class
    @log_class || DEFAULT_LOGGER_CLASS
  end

  def self.logger=(logger = log_class.new(log_path, log_rotation))
    @logger = logger || log_class.new(log_path, log_rotation)
  end

  def self.logger
    @logger || log_class.new(log_path, log_rotation)
  end

  def self.run(name, &process)
    new(name, &process)
  end

  def initialize(name, process, parameters = DEFAULT_PARAMETERS.call)
    @name = name
    @process = process
    @options = (parameters || DEFAULT_PARAMETERS.call).options

    if @options.respond_to?(:daemon)
      Daemon.new(name) do
        @process.call(@options)
      end
    else
      @process.call(@options)
    end
  end
end

require_relative "dante/version"
require_relative "dante/command"
require_relative "dante/daemon"
