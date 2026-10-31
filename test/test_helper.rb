require 'rubygems'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'minitest/autorun'
$:.unshift File.expand_path("../../lib", __FILE__)
require 'dante'

module DanteTestHarness
  TEST_PID = Process.pid

  # The signal handlers in place before any test ran; Runner#start replaces them in
  # the test process itself whenever a test runs a runner in the foreground.
  ORIGINAL_TRAPS = %w(INT TERM).each_with_object({}) do |sig, traps|
    traps[sig] = trap(sig, 'DEFAULT')
    trap(sig, traps[sig])
  end

  # Daemons are forked from inside a test, so every forked process inherits the at_exit
  # handlers of the test process (minitest's among them). Make forked processes leave
  # without running them. It is registered during the run, after minitest's own handler,
  # so it runs first.
  def self.install_fork_guard
    return if @fork_guard_installed
    @fork_guard_installed = true
    at_exit do
      next if Process.pid == TEST_PID
      exit!($!.is_a?(SystemExit) ? $!.status : ($! ? 1 : 0))
    end
  end

  def before_setup
    super
    DanteTestHarness.install_fork_guard
    @tmpdir = Dir.mktmpdir('dante-test-')
    @original_argv = ARGV.dup
    ARGV.clear
  end

  def after_teardown
    stop_daemons
  ensure
    ARGV.replace(@original_argv)
    ORIGINAL_TRAPS.each { |sig, handler| trap(sig, handler) }
    FileUtils.rm_rf(@tmpdir)
    super
  end

  # A path inside this test's own temporary directory.
  def tmp_path(name)
    File.join(@tmpdir, name)
  end

  # Polls until the block returns a truthy value and returns it, or returns nil once
  # timeout seconds have passed.
  def wait_until(timeout = 10, interval = 0.05)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep interval
    end
  end

  # The pid of the daemon recorded in pid_path.
  def daemon_pid(pid_path)
    pid = wait_until { File.exist?(pid_path) && (n = File.read(pid_path).to_i) > 0 && n }
    assert pid, "no pid written to #{pid_path}"
    pid
  end

  # Waits until a daemon has reached its startup block, shown by it creating path (and
  # writing pattern to it). Runner#daemonize returns once the pid file exists, before the
  # daemon has installed its INT and TERM handlers.
  def wait_for_output(path, pattern = //)
    assert wait_until { File.exist?(path) && File.read(path) =~ pattern }, "#{path} never matched #{pattern.inspect}"
  end

  # Waits for a daemon to exit (it is not our child: init reaps it).
  def wait_for_exit(pid, timeout = 10)
    assert wait_until(timeout) { !process_alive?(pid) }, "process #{pid} still running after #{timeout}s"
  end

  # Whether pid is a live process. A zombie counts as gone: it has exited and only waits
  # for its parent (init, for a daemon) to reap it.
  # ceiling: zombies are recognised through /proc (Linux) only; elsewhere a zombie counts
  # as alive until init reaps it, which only makes the waits longer.
  def process_alive?(pid)
    Process.kill(0, pid)
    stat = "/proc/#{pid}/stat"
    !(File.exist?(stat) && File.read(stat)[/\) (\S)/, 1] == 'Z')
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # Stops every daemon whose pid file is in this test's directory, even when the test
  # failed: SIGTERM first, then SIGKILL for daemons that trap SIGTERM.
  # ceiling: a pid file left by a daemon that already exited is trusted while its pid is
  # alive, so a pid reused within the test's lifetime would be signalled; checking the
  # process start time in /proc would rule that out.
  def stop_daemons
    Dir[File.join(@tmpdir, '**', '*.pid')].each do |pid_file|
      pid = File.read(pid_file).to_i
      begin
        next unless pid > 0 && process_alive?(pid)
        %w(TERM KILL).each do |sig|
          Process.kill(sig, pid)
          break if wait_until(5) { !process_alive?(pid) }
        end
      rescue Errno::ESRCH
        next
      end
      raise "daemon #{pid} from #{pid_file} survived SIGKILL" if process_alive?(pid)
    end
  end
end

Minitest::Test.send(:include, DanteTestHarness)

## Kernel Extensions

module Kernel
  # Redirect standard out and standard error to a file and return what was written
  # capture_stdout { any_commands; you_want } => "all output from the commands"
  #
  # The file is a real IO rather than a StringIO so that a daemon forked inside the block
  # reopens $stdout onto its log file, as it does outside the tests.
  def capture_stdout
    return yield if ENV['DEBUG'] # Skip if debug mode

    Tempfile.create('stdout', @tmpdir || Dir.tmpdir) do |out|
      out.sync = true
      $stdout = out
      $stderr = out
      yield
      File.read(out.path)
    end
  ensure
    $stdout = STDOUT
    $stderr = STDERR
  end
end

# Process fixture
class TestingProcess
  attr_reader :tmp_path

  def initialize(name, dir)
    @tmp_path = File.join(dir, "dante-#{name}.log")
  end # initialize

  def run_a!(data=nil)
    @tmp = File.new(@tmp_path, 'w')
    @tmp.puts("Started")
    @tmp.puts "Data is: #{data}" if data
    @tmp.close
  end # run_a!

  def run_b!(port=9090)
    begin
      @tmp = File.new(@tmp_path, 'w')
      @tmp.print "Started on #{port}!!"
      sleep(100)
    rescue Interrupt
      @tmp.print "Interrupt!!"
      exit
    ensure
      @tmp.print "Closing!!"
      @tmp.close
    end
  end # run_b!

  # For logging test
  def run_c!(port=9091)
    puts "Started on #{port}!!"
    sleep(100)
  rescue Interrupt
    puts "Interrupt!!"
    exit
  ensure
    puts "Closing!!"
  end

  # Survives SIGTERM (and SIGINT): only SIGKILL stops it
  def run_d!(data=nil)
    p ['The rescuer']
    sleep 100
  rescue SystemExit, SignalException
    p ['Saved']
    retry
  end

end # TestingProcess
