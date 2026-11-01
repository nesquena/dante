require 'stringio'
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

  describe "with daemonize set to false and a log file" do
    it "writes its output to the log file" do
      logfile = tmp_path('dante-foreground.log')
      capture_stdout {
        pid = fork do
          Dante::Runner.new('test-process', :daemonize => false, :log_path => logfile) { puts "Started" }.execute
          exit!(0)
        end
        Process.wait(pid) }

      assert_equal "Started\n", (File.read(logfile) if File.exist?(logfile))
    end
  end # daemonize false

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

    it "creates the log file with mode 0644 less the umask" do
      assert_equal "640", "%o" % (File.stat(@logfile).mode & 0777)
    end
  end # umask

  describe "with daemonize flag and something at the pid file's path already" do
    before do
      @pid_path = tmp_path('dante.pid')
      @other = tmp_path('other-file')
      File.write(@other, "not a pid\n")
    end

    # Starts a daemon on @pid_path and returns its pid.
    def start_daemon
      started = tmp_path('started')
      capture_stdout {
        Dante::Runner.new('test-process', :daemonize => true, :pid_path => @pid_path, :log_path => tmp_path('dante.log')) {
          File.write(started, ""); sleep 100 }.execute }
      wait_for_output(started)
      daemon_pid(@pid_path)
    end

    it "replaces a symlink with the pid file instead of writing through it" do
      File.symlink(@other, @pid_path)
      pid = start_daemon

      refute File.symlink?(@pid_path), "the pid file is still a symlink"
      assert_equal "#{pid}\n", File.read(@pid_path)
      assert_equal "not a pid\n", File.read(@other)
      assert_empty Dir[File.join(@tmpdir, '*.tmp')], "temporary file left behind"
    end

    it "replaces a hard link to another file instead of writing into it" do
      File.link(@other, @pid_path)
      pid = start_daemon

      assert_equal "#{pid}\n", File.read(@pid_path)
      assert_equal "not a pid\n", File.read(@other)
    end
  end # pid file path taken

  describe "with a log file there already" do
    # Runs a runner in the foreground in a forked child, writing to log_path.
    def run_with_log(log_path)
      capture_stdout {
        pid = fork do
          Dante::Runner.new('test-process', :log_path => log_path) { puts "Started" }.execute
          exit!(0)
        end
        Process.wait(pid) }
    end

    it "appends to it and keeps its mode" do
      logfile = tmp_path('dante.log')
      File.write(logfile, "earlier line\n")
      File.chmod(0600, logfile)
      run_with_log(logfile)

      assert_equal "earlier line\nStarted\n", File.read(logfile)
      assert_equal "600", "%o" % (File.stat(logfile).mode & 0777)
    end

    it "follows a symlink to it, and keeps the mode of the file it points to" do
      target = tmp_path('target.log')
      File.write(target, "")
      File.chmod(0600, target)
      logfile = tmp_path('dante.log')
      File.symlink(target, logfile)
      run_with_log(logfile)

      assert File.symlink?(logfile)
      assert_equal "Started\n", File.read(target)
      assert_equal "600", "%o" % (File.stat(target).mode & 0777)
    end
  end # existing log file

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

    it "gives the daemon /dev/null as its standard input" do
      stdin_path = tmp_path('daemon-stdin')
      status, error = run_with_socket_streams do
        Dante::Runner.new('test-process', :daemonize => true, :pid_path => tmp_path('dante.pid'), :log_path => tmp_path('dante.log')) {
          File.write("#{stdin_path}.tmp", null_device?($stdin) ? "/dev/null" : $stdin.stat.ftype)
          File.rename("#{stdin_path}.tmp", stdin_path)
          sleep 100 }.execute
      end

      assert_equal [0, ""], [status, error]
      wait_for_output(stdin_path)
      assert_equal "/dev/null", File.read(stdin_path)
    end

    it "gives the daemon /dev/null as its standard input when $stdin is not STDIN" do
      stdin_path = tmp_path('daemon-stdin')
      status, error = run_with_socket_streams do
        $stdin = StringIO.new("typed")
        started = Dante::Runner.new('test-process', :daemonize => true, :pid_path => tmp_path('dante.pid'), :log_path => tmp_path('dante.log')) {
          File.write("#{stdin_path}.tmp", null_device?(STDIN) ? "/dev/null" : STDIN.stat.ftype)
          File.rename("#{stdin_path}.tmp", stdin_path)
          sleep 100 }.execute
        raise "not started" unless started
      end

      assert_equal [0, ""], [status, error]
      wait_for_output(stdin_path)
      assert_equal "/dev/null", File.read(stdin_path)
    end

    it "gives the daemon /dev/null as its standard input when STDIN is closed" do
      stdin_path = tmp_path('daemon-stdin')
      status, error = run_with_socket_streams do
        STDIN.close
        started = Dante::Runner.new('test-process', :daemonize => true, :pid_path => tmp_path('dante.pid'), :log_path => tmp_path('dante.log')) {
          fd0 = IO.for_fd(0, autoclose: false)
          File.write("#{stdin_path}.tmp", null_device?(fd0) ? "/dev/null" : fd0.stat.ftype)
          File.rename("#{stdin_path}.tmp", stdin_path)
          sleep 100 }.execute
        raise "not started" unless started
      end

      assert_equal [0, ""], [status, error]
      wait_for_output(stdin_path)
      assert_equal "/dev/null", File.read(stdin_path)
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

    it "does not count a number too large for a pid as a daemon, running or to stop" do
      ["2147483648\n", "99999999999999999999\n"].each do |content|
        File.write(@pid_path, content)
        runner = Dante::Runner.new('test-process', :pid_path => @pid_path)
        assert_equal false, runner.daemon_running?, "pid file #{content.inspect}"
        assert_equal "No test-process processes are running\n", capture_stdout { runner.stop }, "pid file #{content.inspect}"
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

    it "restarts the daemon as a daemon with #restart" do
      ran_in = tmp_path('ran-in')
      test_pid = Process.pid
      runner = Dante::Runner.new('test-process', @run_options) {
        File.write("#{ran_in}.tmp", Process.pid.to_s)
        File.rename("#{ran_in}.tmp", ran_in)
        sleep 100 unless Process.pid == test_pid } # returns if it runs in this process
      result = nil
      output = capture_stdout { result = runner.restart }

      wait_for_output(ran_in)
      refute_equal test_pid.to_s, File.read(ran_in), "the service ran in the caller"
      assert_equal true, result
      assert_match(/Daemonized process killed after term.*Daemon has started successfully/m, output)
      refute process_alive?(@pid), "the first daemon is still running"
      assert_equal daemon_pid(@pid_path).to_s, File.read(ran_in)
    end

    it "neither stops nor restarts the daemon with :kill or :restart given as false" do
      [{ :kill => false }, { :restart => false }].each do |off|
        output = capture_stdout {
          Dante::Runner.new('test-process', @run_options.merge(off)) { sleep 100 }.execute }

        assert_equal ["Process is already started\n"], output.lines.grep_v(/: warning: /), off.inspect
        assert_equal "#{@pid}\n", File.read(@pid_path), off.inspect
        assert process_alive?(@pid), off.inspect
      end
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

  describe "with daemonize flag, stopping a daemon while its pid file changes" do
    before do
      @pid_path = tmp_path('dante.pid')
      @ready = tmp_path('ready')
    end

    after do
      if @replacement
        Process.kill('KILL', @replacement)
        Process.wait(@replacement)
      end
    end

    # Starts a daemon that runs on_term when it gets SIGTERM, and returns its pid.
    def start_daemon(pid_path = @pid_path, &on_term)
      ready = @ready
      capture_stdout {
        Dante::Runner.new('test-process', :daemonize => true, :pid_path => pid_path, :log_path => tmp_path('dante.log')) {
          trap('TERM', &on_term) if on_term
          File.write(ready, "")
          sleep 100 }.execute }
      wait_for_output(ready)
      daemon_pid(pid_path)
    end

    it "stops it from two stops at once, neither of them failing" do
      pid = start_daemon { sleep 0.5; exit }
      output = capture_stdout {
        stoppers = 2.times.map { Thread.new { Dante::Runner.new('test-process', :pid_path => @pid_path).stop } }
        stoppers.each { |t| t.report_on_exception = false }
        stoppers.each(&:value) }

      assert_equal 2, output.scan(/Daemonized process killed after term/).size, output
      refute process_alive?(pid)
      refute File.exist?(@pid_path), "pid file left behind"
    end

    it "keeps the pid file when a new daemon recorded its pid there meanwhile" do
      replacement = @replacement = spawn('sleep', '60')
      pid_path = @pid_path
      pid = start_daemon { File.write(pid_path, "#{replacement}\n"); exit }
      output = capture_stdout { Dante::Runner.new('test-process', :pid_path => @pid_path).stop }

      assert_match(/Daemonized process killed after term/, output)
      refute process_alive?(pid)
      assert_equal "#{replacement}\n", File.read(@pid_path)
    end

    it "sends SIGKILL with :force to the daemon it signalled, not to a new one in the pid file" do
      replacement = @replacement = spawn('sleep', '60')
      pid_path = @pid_path
      pid = start_daemon { File.write(pid_path, "#{replacement}\n") } # survives SIGTERM
      output = capture_stdout { Dante::Runner.new('test-process', :pid_path => @pid_path, :force => true).stop }

      assert_match(/Sent SIGKILL to PID: #{pid} /, output)
      assert_match(/Daemonized process killed after kill/, output)
      refute process_alive?(pid)
      assert process_alive?(replacement), "the new daemon was killed"
      assert_equal "#{replacement}\n", File.read(@pid_path)
    end

    it "returns soon after the daemon stops, well within the second it used to wait first" do
      # A process of this test's that takes 0.2 seconds to stop on SIGTERM, reaped as soon
      # as it exits (a daemon is reaped by init), stands in for the daemon.
      script = "trap('TERM') { sleep 0.2; exit }; File.write(ARGV[0], ''); sleep 100"
      pid = spawn(RbConfig.ruby, '-e', script, @ready)
      reaper = Process.detach(pid)
      wait_for_output(@ready)
      File.write(@pid_path, "#{pid}\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = capture_stdout { Dante::Runner.new('test-process', :pid_path => @pid_path).stop }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_match(/Daemonized process killed after term/, output)
      assert_operator elapsed, :<, 0.8
    ensure
      if reaper && reaper.alive?
        Process.kill('KILL', pid)
        reaper.join
      end
    end

    it "stops a daemon whose pid file path has glob characters in it" do
      pid_path = tmp_path('run[1]/dante.pid')
      pid = start_daemon(pid_path)
      output = capture_stdout { Dante::Runner.new('test-process', :pid_path => pid_path).stop }

      assert_match(/Daemonized process killed after term/, output)
      refute process_alive?(pid)
      refute File.exist?(pid_path), "pid file left behind"
    end
  end # pid file changes

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

    it "removes the pid file the daemon left" do
      pid_path = tmp_path('dante.pid')
      result = nil
      capture_stdout {
        result = Dante::Runner.new('test-process', :daemonize => true, :pid_path => pid_path,
                                   :log_path => tmp_path('dante.log')) { raise "boom" }.execute }

      assert_equal false, result
      assert_match(/Starting test-process/, File.read(tmp_path('dante.log'))) # it recorded its pid and started
      refute File.exist?(pid_path), "the dead daemon's pid file was left behind"
    end

    it "keeps the pid file when it names another process" do
      pid_path = tmp_path('dante.pid')
      other = spawn('sleep', '30')
      # The daemon records another process's pid, as if another start had replaced the
      # pid file after this daemon wrote it.
      other_runner = Class.new(Dante::Runner) do
        define_method(:store_pid) { |_pid| super(other) }
      end
      result = nil
      capture_stdout {
        result = other_runner.new('test-process', :daemonize => true, :pid_path => pid_path,
                                  :log_path => tmp_path('dante.log')) { raise "boom" }.execute }

      assert_equal false, result
      assert_equal "#{other}\n", File.read(pid_path)
    ensure
      if other
        Process.kill('KILL', other)
        Process.wait(other)
      end
    end
  end # dies after recording its pid

  describe "with daemonize flag, interrupted while the daemon starts up" do
    it "leaves no zombie behind" do
      pid_path = tmp_path('dante.pid')
      leader_path = tmp_path('leader')
      leader = nil
      # The daemon records its parent, the session leader, which then waits out the
      # grace period while the caller waits for it; that wait is interrupted.
      interrupter = Thread.new(Thread.current) do |caller|
        leader = wait_until { File.exist?(leader_path) && (n = File.read(leader_path).to_i) > 0 && n }
        caller.raise(Interrupt) if leader
      end
      capture_stdout {
        assert_raises(Interrupt) {
          Dante::Runner.new('test-process', :daemonize => true, :pid_path => pid_path, :log_path => tmp_path('dante.log')) {
            File.write("#{leader_path}.tmp", Process.ppid.to_s)
            File.rename("#{leader_path}.tmp", leader_path)
            sleep 100 }.execute } }
      interrupter.join
      assert leader, "the daemon never recorded its parent"

      # A zombie still answers signal 0; a reaped process does not.
      gone = wait_until(10) do
        begin
          Process.kill(0, leader)
          false
        rescue Errno::ESRCH
          true
        end
      end
      assert gone, "the session leader #{leader} was left as a zombie"
    ensure
      begin
        Process.waitpid(leader) if leader
      rescue Errno::ECHILD
      end
    end
  end # interrupted while starting

  describe "with daemonize flag, in a program of its own" do
    # Runs script with dante loaded in a separate Ruby process, passing it args, and
    # returns what it printed, without Ruby 2.7's -w warnings. A process of its own,
    # because the test harness keeps forked processes from running at_exit handlers.
    # It runs outside Bundler's environment: it needs only dante, and bundler/setup
    # would print git's errors where the tree is not a git checkout.
    def run_program(script, *args)
      lib = File.expand_path('../../lib', __FILE__)
      run = lambda { IO.popen([RbConfig.ruby, '-I', lib, '-rdante', '-e', script, *args], :err => [:child, :out], &:read) }
      output = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
      output.lines.grep_v(/: warning: /).join
    end

    before do
      @pid_path = tmp_path('dante.pid')
      @logfile = tmp_path('dante.log')
    end

    it "reports a running daemon as started whatever the program's at_exit handlers do" do
      output = run_program(<<-RUBY, @pid_path, @logfile)
        main = Process.pid
        at_exit { exit 1 if Process.pid != main }
        p Dante::Runner.new('test-process', :daemonize => true, :pid_path => ARGV[0], :log_path => ARGV[1]) { sleep 30 }.execute
      RUBY

      assert_equal "Daemon has started successfully\ntrue\n", output
      pid = daemon_pid(@pid_path)
      Process.kill('TERM', pid)
      wait_for_exit(pid)
    end

    it "reports whether the daemon started when the program ignores SIGCHLD" do
      script = <<-RUBY
        trap('CHLD', 'IGNORE')
        p Dante::Runner.new('test-process', :daemonize => true, :pid_path => ARGV[0], :log_path => ARGV[1]) {
          raise "boom" if ARGV[2] == 'crash'
          sleep 30 }.execute
      RUBY

      assert_equal "Daemon has started successfully\ntrue\n", run_program(script, @pid_path, @logfile, 'run')
      pid = daemon_pid(@pid_path)
      Process.kill('TERM', pid)
      wait_for_exit(pid)

      crash_pid_path = tmp_path('crash.pid')
      assert_equal "Daemonized process couldn't be started\nfalse\n", run_program(script, crash_pid_path, @logfile, 'crash')
      refute File.exist?(crash_pid_path), "the dead daemon's pid file was left behind"
    end
  end # program of its own

  describe "with the -p option" do
    it "passes the port to the startup block as an Integer" do
      ARGV.replace(['-p', '1234'])
      port = nil
      capture_stdout { Dante::Runner.new('test-process').execute { |opts| port = opts[:port] } }

      assert_equal 1234, port
      assert_kind_of Integer, port
    end
  end # -p

  describe "with the :argv option" do
    before do
      ARGV.replace(['--host-program-flag', 'file.rb']) # options dante does not know
    end

    # The port the startup block of runner gets, and ARGV afterwards.
    def port_from(runner, opts = {})
      port = :not_run
      capture_stdout { runner.execute(opts) { |o| port = o[:port] } }
      [port, ARGV]
    end

    it "parses the given options instead of ARGV, and leaves both arrays as they were" do
      argv = ['-p', '1234', 'extra'].freeze

      assert_equal [1234, ['--host-program-flag', 'file.rb']], port_from(Dante::Runner.new('test-process', :argv => argv))
      assert_equal ['-p', '1234', 'extra'], argv
    end

    it "parses nothing when given an empty array" do
      assert_equal [nil, ['--host-program-flag', 'file.rb']], port_from(Dante::Runner.new('test-process', :argv => []))
    end

    it "takes the options to parse from execute too" do
      assert_equal [4321, ['--host-program-flag', 'file.rb']], port_from(Dante::Runner.new('test-process'), :argv => ['-p', '4321'])
    end

    it "takes the options to parse from Dante.run" do
      port = :not_run
      capture_stdout { Dante.run('test-process', :argv => ['-p', '1234']) { |o| port = o[:port] } }

      assert_equal 1234, port
    end
  end # :argv

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
