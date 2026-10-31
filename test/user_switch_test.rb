require File.expand_path('../test_helper', __FILE__)
require 'etc'

# Switching user and group needs root. CI runs this file a second time under sudo.
describe "dante runner switching user and group" do
  before do
    skip "switching user and group needs root (CI runs this file under sudo)" unless Process.euid == 0
    skip "reads credentials from /proc" unless File.exist?("/proc/self/status")
    @nobody = begin
      Etc.getpwnam('nobody')
    rescue ArgumentError
      skip "no 'nobody' user"
    end
    @nobody_group = Etc.getgrgid(@nobody.gid).name

    # The switched process must be able to write its pid and log files.
    File.chmod(0755, @tmpdir)
    @dir = tmp_path('shared')
    Dir.mkdir(@dir)
    File.chmod(0777, @dir)
    @pid_path = File.join(@dir, 'dante.pid')
    @log_path = File.join(@dir, 'dante.log')
    @status_path = File.join(@dir, 'status')
  end

  # Runs the block in a forked child that starts with the given supplementary groups,
  # as a process started by root might have. Fails the test if the block raises. The
  # error goes through a file rather than a pipe, which a daemon started by the block
  # would hold open.
  def run_in_child(groups = [0, 4, 27])
    error_path = tmp_path('child-error')
    pid = fork do
      error = File.open(error_path, 'w') # opened before the block switches user
      begin
        $stdout = $stderr = File.open(tmp_path('child.out'), 'w')
        Process.groups = groups
        yield
      rescue Exception => e
        error.write("#{e.class}: #{e.message}")
        exit!(1)
      end
      exit!(0)
    end
    Process.wait(pid)
    assert_equal [0, ""], [$?.exitstatus, File.read(error_path)]
  end

  # The real, effective, saved and filesystem uids and gids and the supplementary
  # groups, from the text of /proc/<pid>/status.
  def credentials(status)
    fields = status.lines.map { |line| line.chomp.split(/:\s*/, 2) }.to_h
    { :uid => fields['Uid'].split.map(&:to_i), :gid => fields['Gid'].split.map(&:to_i),
      :groups => fields['Groups'].to_s.split.map(&:to_i).sort }
  end

  # The supplementary groups the group database gives user, with primary group gid.
  def groups_of(user, gid)
    gids = [gid]
    Etc.group { |group| gids << group.gid if group.mem.include?(user) }
    gids.uniq.sort
  end

  # A uid with no passwd entry.
  def unused_uid
    (4242..60000).find do |uid|
      begin
        Etc.getpwuid(uid)
        false
      rescue ArgumentError
        true
      end
    end
  end

  # The startup block of a foreground runner: records the process's credentials.
  def record_status
    status_path = @status_path
    lambda { |_opts| File.write(status_path, File.read('/proc/self/status')) }
  end

  it "gives a daemon started with -u the user's uid, primary group and groups" do
    run_in_child do
      ARGV.replace(['-d', '-P', @pid_path, '-l', @log_path, '-u', 'nobody'])
      Dante::Runner.new('test-process').execute { sleep 100 }
    end
    creds = credentials(File.read("/proc/#{daemon_pid(@pid_path)}/status"))

    assert_equal [@nobody.uid] * 4, creds[:uid]
    assert_equal [@nobody.gid] * 4, creds[:gid]
    assert_equal groups_of('nobody', @nobody.gid), creds[:groups]
    assert_empty creds[:groups] & [0, 4, 27]
  end

  it "gives a daemon started with -u and -G that group and the user's groups" do
    group = begin
      Etc.getgrgid(1)
    rescue ArgumentError
      skip "no group with gid 1"
    end
    run_in_child do
      ARGV.replace(['-d', '-P', @pid_path, '-l', @log_path, '-u', 'nobody', '-G', group.name])
      Dante::Runner.new('test-process').execute { sleep 100 }
    end
    creds = credentials(File.read("/proc/#{daemon_pid(@pid_path)}/status"))

    assert_equal [@nobody.uid] * 4, creds[:uid]
    assert_equal [group.gid] * 4, creds[:gid]
    assert_equal groups_of('nobody', group.gid), creds[:groups]
    assert_empty creds[:groups] & [0, 4, 27]
  end

  it "keeps root's uid and leaves only the new group with -G alone" do
    run_in_child do
      ARGV.replace(['-G', @nobody_group])
      Dante::Runner.new('test-process').execute(&record_status)
    end
    creds = credentials(File.read(@status_path))

    assert_equal [0] * 4, creds[:uid]
    assert_equal [@nobody.gid] * 4, creds[:gid]
    assert_equal [@nobody.gid], creds[:groups]
  end

  it "accepts a uid, and gives it the user's primary group and groups" do
    run_in_child do
      Dante::Runner.new('test-process').execute(:user => @nobody.uid, &record_status)
    end
    creds = credentials(File.read(@status_path))

    assert_equal [@nobody.uid] * 4, creds[:uid]
    assert_equal [@nobody.gid] * 4, creds[:gid]
    assert_equal groups_of('nobody', @nobody.gid), creds[:groups]
  end

  it "keeps the group of a uid with no passwd entry and leaves only that group" do
    uid = unused_uid
    run_in_child do
      Dante::Runner.new('test-process').execute(:user => uid, &record_status)
    end
    creds = credentials(File.read(@status_path))

    assert_equal [uid] * 4, creds[:uid]
    assert_equal [0] * 4, creds[:gid]
    assert_equal [0], creds[:groups]
  end

  it "gives a uid with no passwd entry the group named by :group" do
    uid = unused_uid
    run_in_child do
      Dante::Runner.new('test-process').execute(:user => uid, :group => @nobody.gid, &record_status)
    end
    creds = credentials(File.read(@status_path))

    assert_equal [uid] * 4, creds[:uid]
    assert_equal [@nobody.gid] * 4, creds[:gid]
    assert_equal [@nobody.gid], creds[:groups]
  end

  it "gives a user its supplementary groups from the group database" do
    member = nil
    Etc.group do |group|
      member ||= group.mem.find { |name| name != 'root' && (Etc.getpwnam(name) rescue nil) }
    end
    skip "no user is a member of a group in the group database" unless member
    passwd = Etc.getpwnam(member)
    run_in_child([0]) do
      Dante::Runner.new('test-process').execute(:user => member, &record_status)
    end
    creds = credentials(File.read(@status_path))

    assert_equal [passwd.uid] * 4, creds[:uid]
    assert_equal [passwd.gid] * 4, creds[:gid]
    assert_equal groups_of(member, passwd.gid), creds[:groups]
    assert_operator creds[:groups].size, :>, 1
  end
end
