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
  end # another user's process

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
