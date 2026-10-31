require File.expand_path('../test_helper', __FILE__)
require 'socket'

describe "dante runner" do

  describe "verify options fails" do
    it "should bubble up exception" do
      runner = Dante::Runner.new('test-process', {key1:"val2"}) {
        raise Exception.new("should not get here!!!")
      }

      runner.verify_options_hook = lambda { |opts|
        raise Exception.new("Look for this exception") if(opts[:key1] != "val1")
      }

      err = assert_raises(Exception) {
        runner.execute
      }

      assert_equal(err.message, "Look for this exception")
    end
  end

  describe "with no daemonize" do
    before do
      @process = TestingProcess.new('a', @tmpdir)
      @runner = Dante::Runner.new('test-process') { @process.run_a! }
      @stdout = capture_stdout { @runner.execute }
    end

    it "prints correct stdout" do
      assert_match(/Starting test-process/, @stdout)
    end

    it "starts successfully when executed" do
      @output = File.read(@process.tmp_path)
      assert_match(/Started/, @output)
    end
  end # no daemonize

  describe "with daemonize flag" do
    before do
      @process = TestingProcess.new('b', @tmpdir)
      @pid_path = tmp_path('dante.pid')
      @run_options = { :daemonize => true, :pid_path => @pid_path, :port => 8080, :log_path => tmp_path('dante-daemon.log') }
      @runner = Dante::Runner.new('test-process-2', @run_options) { |opts|
        @process.run_b!(opts[:port]) }
      @stdout = capture_stdout { @runner.execute }
      wait_for_output(@process.tmp_path)
    end

    it "can properly handles aborts and starts / stops on INT" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      Process.kill "INT", @pid
      wait_for_exit(@pid)
      @output = File.read(@process.tmp_path)

      assert_match(/Started on 8080!!/, @output)
      assert_match(/Interrupt!!/, @output)
      assert_match(/Closing!!/, @output)
    end

    it "can properly handles aborts and starts / stops on TERM" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      Process.kill "TERM", @pid
      wait_for_exit(@pid)
      @output = File.read(@process.tmp_path)

      assert_match(/Started on 8080!!/, @output)
      assert_match(/Closing!!/, @output)
      refute_match(/Interrupt!!/, @output)
    end

    it "can be stopped with #stop, which removes the pid file" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      @stop_output = capture_stdout { @runner.stop }

      assert_match(/Daemonized process killed after term/, @stop_output)
      refute File.exist?(@pid_path), "pid file left behind after stop"
      assert_match(/Closing!!/, File.read(@process.tmp_path))
      refute_match(/Interrupt!!/, File.read(@process.tmp_path)) # stopped with TERM, not INT
    end
  end # daemonize

  describe "daemonize with block on sigterm" do
    before do
      @logfile = tmp_path('dante-logging.log')
      @pid_path = tmp_path('dante.pid')
      @process = TestingProcess.new('f1', @tmpdir)
      @run_options = { :daemonize => true, :pid_path => @pid_path, :log_path => @logfile }
      @runner = Dante::Runner.new('test-process-f1', @run_options) { |opts|
        @process.run_d! }
      @stdout = capture_stdout { @runner.execute }
      wait_for_output(@logfile, /The rescuer/)
    end

    it "cannot be stopped without force flag" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      @stop_output = capture_stdout { @runner.stop }
      @output = File.read(@logfile)

      assert_match(/Trying to stop test-process/, @output)
      assert_match(/Failed to kill daemonized process/, @stop_output)
      refute_match(/Daemonized process killed after kill/, @stop_output)
      assert File.exist?(@pid_path), "pid file removed although the daemon is still running"
    end
  end

  describe "daemonize with block on sigkill" do
    before do
      @logfile = tmp_path('dante-logging.log')
      @pid_path = tmp_path('dante.pid')
      @process = TestingProcess.new('f2', @tmpdir)
      @run_options = { :daemonize => true, :pid_path => @pid_path, :log_path => @logfile, force: true }
      @runner = Dante::Runner.new('test-process-f2', @run_options) { |opts|
        @process.run_d! }
      @stdout = capture_stdout { @runner.execute }
      wait_for_output(@logfile, /The rescuer/)
    end

    it "can be stopped without force flag" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      @stop_output = capture_stdout { @runner.stop }
      @output = File.read(@logfile)

      assert_match(/Trying to stop test-process/, @output)
      assert_match(/Failed to kill daemonized process/, @stop_output)
      assert_match(/Daemonized process killed after kill/, @stop_output)
      refute File.exist?(@pid_path), "pid file left behind after a forced stop"
    end
  end

  describe "with daemonize flag and log file specified" do
    before do
      @logfile = tmp_path('dante-logging.log')
      @pid_path = tmp_path('dante.pid')
      @process = TestingProcess.new('c', @tmpdir)
      @run_options = { :daemonize => true, :pid_path => @pid_path, :port => 8081, :log_path => @logfile }
      @runner = Dante::Runner.new('test-process-2', @run_options) { |opts|
        @process.run_c!(opts[:port]) }
      @stdout = capture_stdout { @runner.execute }
      wait_for_output(@logfile, /Started on 8081!!/)
    end

    it "can properly handles log to file and aborts on INT" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      Process.kill "INT", @pid
      wait_for_exit(@pid)
      @output = File.read(@logfile)

      assert_match(/Started on 8081!!/, @output)
      assert_match(/Interrupt!!/, @output)
      assert_match(/Closing!!/, @output)
    end
  end

  describe "with daemonize flag and logging flag enabled, and debug flag disabled" do
    before do
      @logfile = tmp_path('dante-logging.log')
      @pid_path = tmp_path('dante.pid')
      @process = TestingProcess.new('c', @tmpdir)
      @run_options = { :daemonize => true, :pid_path => @pid_path, :port => 8081, :log_path => @logfile, :debug => false }
      @runner = Dante::Runner.new('test-process-2', @run_options) { |opts|
        @process.run_c!(opts[:port]) }
      @stdout = capture_stdout { @runner.execute }
      wait_for_output(@logfile, /Started on 8081!!/)
    end

    it "can properly handles log to file and aborts on INT" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      Process.kill "INT", @pid
      wait_for_exit(@pid)
      @output = File.read(@logfile)

      assert_match(/Started on 8081!!/, @output)
      assert_match(/Interrupt received/, @output)
      assert_match(/Closing!!/, @output)
    end
  end


  describe "with execute accepting block" do
    before do
      @process = TestingProcess.new('b', @tmpdir)
      @pid_path = tmp_path('dante.pid')
      @run_options = { :daemonize => true, :pid_path => @pid_path, :port => 8080, :log_path => tmp_path('dante-daemon.log') }
      @runner = Dante::Runner.new('test-process-2', @run_options)
      @stdout = capture_stdout { @runner.execute { |opts| @process.run_b!(opts[:port]) } }
      wait_for_output(@process.tmp_path)
    end

    it "can properly handles aborts and starts / stops on INT" do
      refute_equal 0, @pid = daemon_pid(@pid_path)
      Process.kill "INT", @pid
      wait_for_exit(@pid)
      @output = File.read(@process.tmp_path)

      assert_match(/Started on 8080!!/, @output)
      assert_match(/Interrupt!!/, @output)
      assert_match(/Closing!!/, @output)
    end
  end # execute with block

  describe "with daemonize flag, stopped while starting up" do
    before do
      # Holds the daemon at its "Starting" message, after its pid file is written and
      # before its startup block runs, and shows that it got there by creating @starting.
      # (It holds before writing the message, so the TERM below never lands mid-write.)
      starting = @starting = tmp_path('starting')
      slow_runner = Class.new(Dante::Runner) do
        define_method(:log) do |message|
          if message.start_with?("Starting")
            File.write(starting, "")
            sleep 10
          end
          super(message)
        end
      end
      @logfile = tmp_path('dante-starting.log')
      @pid_path = tmp_path('dante.pid')
      @runner = slow_runner.new('test-process', :daemonize => true, :pid_path => @pid_path, :log_path => @logfile) { sleep 100 }
      @stdout = capture_stdout { @runner.execute }
    end

    it "stops through its TERM handler once it has reported starting" do
      assert_match(/Daemon has started successfully/, @stdout)
      @pid = daemon_pid(@pid_path)
      wait_for_output(@starting)
      Process.kill "TERM", @pid
      wait_for_exit(@pid)

      assert_match(/Trying to stop test-process/, File.read(@logfile))
    end
  end # stopped while starting up

  describe "with daemonize flag and a umask" do
    before do
      @original_umask = File.umask(0027)
      @logfile = tmp_path('dante-umask.log')
      @pid_path = tmp_path('dante.pid')
      @created = tmp_path('created-by-daemon')
      created = @created
      @runner = Dante::Runner.new('test-process', :daemonize => true, :pid_path => @pid_path, :log_path => @logfile) {
        File.write(created, "x")
        sleep 100 }
      @stdout = capture_stdout { @runner.execute }
      wait_for_output(@created)
    end

    after do
      File.umask(@original_umask)
    end

    it "creates files with the umask of the process that started it" do
      assert_equal "640", "%o" % (File.stat(@created).mode & 0777)
    end

    it "still gives the log file mode 0644" do
      assert_equal 0644, File.stat(@logfile).mode & 0777
    end
  end # umask

  describe "with the standard streams connected to a socket" do
    # Runs the block in a forked child whose stdin, stdout and stderr are one end of a
    # socket pair, as under Spring or Zeus. Returns the child's exit status and the
    # error it raised, if any. The error goes through a file rather than a pipe, which
    # a daemon started by the block would hold open.
    def run_with_socket_streams
      error_path = tmp_path('child-error')
      pid = fork do
        begin
          socket, _peer = UNIXSocket.pair
          [STDIN, STDOUT, STDERR].each { |io| io.reopen(socket) }
          $stdin, $stdout, $stderr = STDIN, STDOUT, STDERR
          yield
        rescue Exception => e
          File.write(error_path, "#{e.class}: #{e.message}")
          exit!(1)
        end
        exit!(0)
      end
      Process.wait(pid)
      [$?.exitstatus, File.exist?(error_path) ? File.read(error_path) : ""]
    end

    def null_device?(io)
      io.stat.chardev? && io.stat.rdev == File.stat(File::NULL).rdev
    end

    it "appends to the log file when run in the foreground" do
      @logfile = tmp_path('dante-socket.log')
      File.write(@logfile, "earlier line\n")
      status, error = run_with_socket_streams do
        Dante::Runner.new('test-process', :log_path => @logfile) { puts "Started" }.execute
      end

      assert_equal [0, ""], [status, error]
      assert_equal "earlier line\nStarted\n", File.read(@logfile)
      assert_equal 0644, File.stat(@logfile).mode & 0777
    end

    it "logs to the log file when daemonized" do
      @logfile = tmp_path('dante-socket.log')
      @pid_path = tmp_path('dante.pid')
      @process = TestingProcess.new('c', @tmpdir)
      status, error = run_with_socket_streams do
        Dante::Runner.new('test-process', :daemonize => true, :pid_path => @pid_path, :log_path => @logfile) {
          @process.run_c!(8082) }.execute
      end

      assert_equal [0, ""], [status, error]
      wait_for_output(@logfile, /Started on 8082!!/)
      assert_equal 0644, File.stat(@logfile).mode & 0777
    end

    it "redirects all three streams to /dev/null without a log file" do
      status, error = run_with_socket_streams do
        Dante::Runner.new('test-process', :log_path => false).send(:redirect_output!)
        streams = [STDIN, STDOUT, STDERR]
        raise "not redirected to /dev/null: #{streams.reject { |io| null_device?(io) }.map(&:fileno)}" unless streams.all? { |io| null_device?(io) }
      end

      assert_equal [0, ""], [status, error]
    end
  end # socket streams

  describe "with the pid file naming a process of another user" do
    before do
      @pid_path = tmp_path('dante.pid')
      if Process.euid == 0
        # A process of root's; the blocks below run as nobody.
        @foreign_pid = @sleeper = spawn('sleep', '60')
      else
        @foreign_pid = 1
        begin
          Process.kill(0, @foreign_pid)
          skip "pid #{@foreign_pid} can be signalled, so there is no process of another user to name"
        rescue Errno::EPERM
        end
      end
      File.write(@pid_path, "#{@foreign_pid}\n")
      File.chmod(0755, @tmpdir)
      File.chmod(0644, @pid_path)
    end

    after do
      FileUtils.rm_f(@pid_path) if @pid_path
      if @sleeper
        Process.kill('KILL', @sleeper)
        Process.wait(@sleeper)
      end
    end

    # Runs the block in a forked child that may not signal @foreign_pid (as nobody, when
    # the tests run as root). Returns what the block returned or raised, and what it
    # printed.
    def run_without_permission_to_signal
      out_path = tmp_path('out')
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        $stdout = File.open(out_path, 'w')
        $stdout.sync = true
        result = begin
          if Process.euid == 0
            nobody = Etc.getpwnam('nobody')
            Process.groups = [nobody.gid]
            Process::GID.change_privilege(nobody.gid)
            Process::UID.change_privilege(nobody.uid)
          end
          raise "still root" if Process.euid == 0
          [:returned, yield]
        rescue Exception => e
          [:raised, "#{e.class}: #{e.message}"]
        end
        writer.write(Marshal.dump(result))
        exit!(0)
      end
      writer.close
      Process.wait(pid)
      [Marshal.load(reader.read), File.read(out_path)]
    ensure
      reader.close if reader && !reader.closed?
    end

    it "reports the daemon as running" do
      result, _output = run_without_permission_to_signal do
        Dante::Runner.new('test-process', :pid_path => @pid_path).daemon_running?
      end

      assert_equal [:returned, true], result
    end

    it "does not start a second daemon" do
      result, output = run_without_permission_to_signal do
        Dante::Runner.new('test-process', :daemonize => true, :pid_path => @pid_path, :log_path => tmp_path('dante.log')) {
          raise "should not get here" }.execute
        nil
      end

      assert_equal [:returned, nil], result
      assert_equal "Process is already started\n", output
    end

    it "reports that it could not stop it with -k, and keeps the pid file" do
      result, output = run_without_permission_to_signal do
        ARGV.replace(['-k', '-P', @pid_path])
        Dante::Runner.new('test-process').execute
        nil
      end

      assert_equal [:returned, nil], result
      assert_match(/Failed to stop! : Operation not permitted/, output)
      assert_match(/Failed to kill daemonized process/, output)
      assert_equal "#{@foreign_pid}\n", File.read(@pid_path)
    end

    it "stops waiting at once when it cannot signal it, even with :force" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, output = run_without_permission_to_signal do
        Dante::Runner.new('test-process', :pid_path => @pid_path, :force => true).stop
        nil
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal [:returned, nil], result
      assert_match(/Failed to kill daemonized process/, output)
      refute_match(/Sent SIG/, output)
      assert_operator elapsed, :<, Dante::Runner::MAX_START_TRIES / 2.0, "waited for a daemon it could not signal"
      assert_equal "#{@foreign_pid}\n", File.read(@pid_path)
    end
  end # another user's process

  describe "with an empty pid file, as left by a crash between creating and writing it" do
    before do
      @pid_path = tmp_path('dante.pid')
      File.write(@pid_path, "")
    end

    it "does not count as a running daemon, nor does a pid file naming no process" do
      ["", "0\n", "-1\n"].each do |content|
        File.write(@pid_path, content)
        assert_equal false, Dante::Runner.new('test-process', :pid_path => @pid_path).daemon_running?, "pid file #{content.inspect}"
      end
    end

    it "starts a daemon in its place" do
      started = tmp_path('started')
      result = nil
      output = capture_stdout {
        result = Dante::Runner.new('test-process', :daemonize => true, :pid_path => @pid_path, :log_path => tmp_path('dante.log')) {
          File.write(started, ""); sleep 100 }.execute }

      assert_equal true, result
      assert_match(/Daemon has started successfully/, output)
      wait_for_output(started)
      assert process_alive?(daemon_pid(@pid_path))
    end

    it "reports that no daemon is running when asked to stop, and signals nothing" do
      # The stop runs in a child leading a process group of its own, which is all that a
      # signal to "pid 0" (the caller's process group) could reach.
      out_path = tmp_path('out')
      pid = fork do
        Process.setpgid(0, 0)
        $stdout = File.open(out_path, 'w')
        $stdout.sync = true
        p Dante::Runner.new('test-process', :pid_path => @pid_path).stop
        exit!(0)
      end
      Process.wait(pid)

      assert_equal "No test-process processes are running\nfalse\n", File.read(out_path)
      assert_equal 0, $?.exitstatus, "the stop ended with #{$?.inspect}"
      assert_equal "", File.read(@pid_path)
    end
  end # empty pid file

  describe "with daemonize flag, controlling a running daemon" do
    before do
      @pid_path = tmp_path('dante.pid')
      @logfile = tmp_path('dante.log')
      @first_started = tmp_path('first-started')
      @run_options = { :daemonize => true, :pid_path => @pid_path, :log_path => @logfile }
      first_started = @first_started
      @start_result = nil
      @stdout = capture_stdout {
        @start_result = Dante::Runner.new('test-process', @run_options) { File.write(first_started, ""); sleep 100 }.execute }
      wait_for_output(@first_started)
      @pid = daemon_pid(@pid_path)
    end

    it "runs the daemon in a session of its own, which it does not lead" do
      assert_equal true, @start_result
      refute_equal Process.getsid, Process.getsid(@pid)
      refute_equal @pid, Process.getsid(@pid)
    end

    it "does not start a second daemon on the same pid file" do
      second_started = tmp_path('second-started')
      result = :not_returned
      output = capture_stdout {
        result = Dante::Runner.new('test-process', @run_options) { File.write(second_started, "") }.execute }

      assert_equal ["Process is already started\n"], output.lines.grep_v(/: warning: /) # Ruby 2.7 -w warns on stderr
      assert_nil result
      assert_equal "#{@pid}\n", File.read(@pid_path)
      assert process_alive?(@pid)
    end

    it "stops the daemon and starts a new one with :restart" do
      second_started = tmp_path('second-started')
      result = nil
      output = capture_stdout {
        result = Dante::Runner.new('test-process', @run_options.merge(:restart => true)) {
          File.write(second_started, ""); sleep 100 }.execute }

      assert_equal true, result
      assert_match(/Daemonized process killed after term.*Daemon has started successfully/m, output)
      refute process_alive?(@pid), "the first daemon is still running"
      wait_for_output(second_started)
      new_pid = daemon_pid(@pid_path)
      refute_equal @pid, new_pid
      assert process_alive?(new_pid)
    end

    it "stops the daemon with -k and removes its pid file" do
      ARGV.replace(['-k', '-P', @pid_path])
      output = capture_stdout { Dante::Runner.new('test-process').execute }

      assert_match(/Sent SIGTERM to PID: #{@pid}/, output)
      assert_match(/Daemonized process killed after term/, output)
      refute process_alive?(@pid), "daemon still running after -k"
      refute File.exist?(@pid_path), "pid file left behind after -k"
    end
  end # controlling a running daemon

  describe "with daemonize flag and no log path" do
    before do
      # Records the log path the daemon would redirect its output to, then sends the
      # output to a file of this test's instead of writing to /var/log.
      recorded = @recorded = tmp_path('recorded-log-path')
      logfile = tmp_path('dante.log')
      recording_runner = Class.new(Dante::Runner) do
        define_method(:redirect_output!) do
          File.write("#{recorded}.tmp", options[:log_path].inspect)
          File.rename("#{recorded}.tmp", recorded)
          options[:log_path] = logfile
          super()
        end
      end
      @pid_path = tmp_path('dante.pid')
      @stdout = capture_stdout {
        recording_runner.new('test-process', :daemonize => true, :pid_path => @pid_path) { sleep 100 }.execute }
      daemon_pid(@pid_path)
      wait_for_output(@recorded)
    end

    it "logs to /var/log/<name>.log" do
      assert_equal '"/var/log/test-process.log"', File.read(@recorded)
    end
  end # default log path

  describe "with daemonize flag, when the daemon dies before recording its pid" do
    it "reports that it could not be started" do
      # The daemon fails to create the pid file's directory, which is a device.
      pid_path = File.join(File::NULL, 'dante.pid')
      result = nil
      output = capture_stdout {
        result = Dante::Runner.new('test-process', :daemonize => true, :pid_path => pid_path,
                                   :log_path => tmp_path('dante.log')) { raise "should not get here" }.execute }

      assert_equal false, result
      assert_match(/Daemonized process couldn't be started/, output)
      refute_match(/started successfully/, output)
    end
  end # dies at once

  describe "with daemonize flag, when the daemon dies right after recording its pid" do
    it "reports that it could not be started" do
      pid_path = tmp_path('dante.pid')
      # After the check made before starting, checks for the daemon only once its pid is
      # recorded, so the check falls in the moment between the daemon starting up and dying.
      checking_runner = Class.new(Dante::Runner) do
        define_method(:daemon_running?) do
          if @checked_before_starting
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
            sleep 0.01 until (File.exist?(pid_path) && File.read(pid_path).to_i > 0) ||
                             Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          end
          @checked_before_starting = true
          super()
        end
      end
      result = nil
      output = capture_stdout {
        result = checking_runner.new('test-process', :daemonize => true, :pid_path => pid_path,
                                     :log_path => tmp_path('dante.log')) { sleep 0.2; raise "boom" }.execute }

      assert_equal false, result
      assert_match(/Daemonized process couldn't be started/, output)
      refute_match(/started successfully/, output)
      assert_match(/Starting test-process/, File.read(tmp_path('dante.log'))) # it did start, then died
    end
  end # dies after recording its pid

  describe "with the -p option" do
    it "passes the port to the startup block as an Integer" do
      ARGV.replace(['-p', '1234'])
      port = nil
      capture_stdout { Dante::Runner.new('test-process').execute { |opts| port = opts[:port] } }

      assert_equal 1234, port
      assert_kind_of Integer, port
    end
  end # -p

  describe "with parsing options" do
    before do
      ARGV.replace(['-t test_text'])
      @process = TestingProcess.new('a', @tmpdir)
      @runner = Dante::Runner.new('test-process')
      @runner.with_options do |opts|
        opts.on("-t", "--test TEST", String, "Test this thing") { |test| options[:test] = test }
      end
      @stdout = capture_stdout { @runner.execute { |opts| @process.run_a!(opts[:test]) } }
    end

    it "prints correct stdout" do
      assert_match(/Starting test-process/, @stdout)
    end

    it "prints correct data" do
      @output = File.read(@process.tmp_path)
      assert_match(/test_text/, @output)
    end

    it "starts successfully when executed" do
      @output = File.read(@process.tmp_path)
      assert_match(/Started/, @output)
    end
  end # options parsing

  describe "with help command" do
    before do
      ARGV.replace(['--help'])
      @process = TestingProcess.new('a', @tmpdir)
      @runner = Dante::Runner.new('test-process')
      @runner.description = "Test process banana"
      @stdout = capture_stdout {
        assert_raises(SystemExit) { @runner.execute { @process.run_a! } }
      }
    end

    it "prints correct stdout" do
      assert_match(/test-process - Test process banana/, @stdout)
    end
  end # help
end
