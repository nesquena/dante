require File.expand_path('../test_helper', __FILE__)

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
