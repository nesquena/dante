require File.expand_path('../test_helper', __FILE__)

describe "dante runner" do
  describe "with no daemonize" do
    before do
      @process = TestingProcess.new('a')
      @runner = Dante::Runner.new('test-process') { @process.run_a! }
      @stdout = capture_stdout { @runner.execute! }
    end

    it "prints correct stdout" do
      assert_match /Starting test-process/, @stdout
    end

    it "starts successfully when executed" do
      @output = File.read(@process.tmp_path)
      assert_match /Started/, @output
    end
  end # no daemonize

  describe "with daemonize flag" do
    before do
      @process = TestingProcess.new('b')
      @run_options = { :daemonize => true, :pid_path => "/tmp/dante.pid", :port => 8080 }
      @runner = Dante::Runner.new('test-process-2', @run_options) { |opts|
        @process.run_b!(opts[:port]) }
      @stdout = capture_stdout { @runner.execute! }
      sleep(1)
    end

    it "can properly handles aborts and starts / stops on INT" do
      refute_equal 0, @pid = `cat /tmp/dante.pid`.to_i
      Process.kill "INT", @pid
      sleep(1) # Wait to complete
      @output = File.read(@process.tmp_path)
      assert_match /Started on 8080!!/, @output
      assert_match /Abort!!/, @output
      assert_match /Closing!!/, @output
    end

    it "can properly handles aborts and starts / stops on TERM" do
      refute_equal 0, @pid = `cat /tmp/dante.pid`.to_i
      Process.kill "TERM", @pid
      sleep(1) # Wait to complete
      @output = File.read(@process.tmp_path)
      assert_match /Started on 8080!!/, @output
      assert_match /Abort!!/, @output
      assert_match /Closing!!/, @output
    end
  end # daemonize
end