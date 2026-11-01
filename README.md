# Dante

Turn any ruby into a daemon.

## Description

Dante is the simplest possible thing that will work to turn arbitrary ruby code into an executable that
can be started via command line or start/stop a daemon, and will store a pid file for you.

If you need to create a ruby executable and you want standard daemon start/stop with pid files
and no hassle, this gem will be a great way to get started.

## Requirements

Dante daemonizes with `fork`, so it needs MRI (CRuby) 2.7 or newer on Unix: Linux, macOS or a BSD. It does not
run on Windows or JRuby, which have no `fork`.

## Installation

Add to your Gemfile:

```ruby
# Gemfile

gem "dante"
```

or to your gemspec:

```ruby
# mygem.gemspec

Gem::Specification.new do |s|
  s.add_dependency "dante"
end
```

## Usage

Dante is meant to be used from any "bin" executable. For instance, to create a binary for a web server, create a file in `bin/myapp`:

```ruby
#!/usr/bin/env ruby

require File.expand_path("../../myapp.rb", __FILE__)

Dante.run('myapp') do |opts|
  # opts: host, pid_path, port, daemonize, user, group
  Thin::Server.start('0.0.0.0', opts[:port]) do
    use Rack::CommonLogger
    use Rack::ShowExceptions
    run MyApp
  end
end
```

Be sure to properly make your bin executable:

```
chmod +x bin/myapp
```

### CLI

This gives your binary several useful things for free:

```
./bin/myapp
```

will start the app undaemonized in the terminal, handling trapping and stopping the process.

```
./bin/myapp -l /var/log/myapp.log
```

will start the app undaemonized in the terminal and redirect all stdout and stderr to the specified logfile.

```
./bin/myapp -p 8080 -d -P /var/run/myapp.pid -l /var/log/myapp.log
```

will daemonize and start the process, storing the pid in the specified pid file. It reports the daemon as
started once the daemon has kept running for a second, and as not started if it exits before then.
All stdout and stderr will be redirected to the specified logfile. If no logfile is specified in daemon mode then all 
stdout and stderr will be directed to /var/log/<myapp name>.log.

```
sudo install -d -o nobody -g nogroup /var/run/myapp /var/log/myapp
sudo ./bin/myapp -d -u nobody -G nogroup -P /var/run/myapp/myapp.pid -l /var/log/myapp/myapp.log
```

will switch to the user nobody before starting, with the group given by `-G`. When started as root, the group
defaults to the user's primary group, and the process takes on the user's supplementary groups (plus the `-G`
group, if given). The switch happens before the pid file and the log file are written, so both must be in
directories that user can write: the defaults, `/var/run/myapp.pid` and `/var/log/myapp.log`, are not, and the
daemon would fail to start. Keep the pid file and the log in directories that only the daemon's user (or root) can
write, never in one that other users can write, such as `/tmp`: another user could put a file or a symlink of
their own at that path.

```
./bin/myapp -k -P /var/run/myapp.pid
```

will stop the daemon whose pid is in the specified pid file: it sends SIGTERM, waits up to 5 seconds for the
daemon to exit, and then removes the pid file. If the daemon is still running, it says "Failed to kill daemonized
process" and keeps the pid file.

```
./bin/myapp -k -f -P /var/run/myapp.pid
```

will do the same, and if the daemon survives SIGTERM, send it SIGKILL (`-f`/`--force`, or `:force => true`) and
wait up to 5 more seconds.

```
./bin/myapp --help
```

Will return a useful help banner message explaining the simple usage. These are all the built-in options:

```
    -p, --port PORT           Specify port
                              (default: )
    -P, --pid FILE            save PID in FILE when using -d option.
                              (default: /var/run/myapp.pid)
    -d, --daemon              Daemonize mode
    -l, --log FILE            Logfile for output
                              (default: /var/log/myapp.log)
    -k, --kill [PORT]         Stop the daemon in the pid file (PORT is ignored)
    -u, --user USER           User to run as
    -G, --group GROUP         Group to run as
    -f, --force               Force kill if SIGTERM fails
    -?, --help                Display this usage information.
```

### Advanced

In many cases, you will need to add custom flags/options or a custom description to your executable. You can do this
easily by using `Dante::Runner` more explicitly:

```ruby
#!/usr/bin/env ruby

require File.expand_path("../../myapp.rb", __FILE__)

# Set default port to 8080
runner = Dante::Runner.new('myapp', :port => 8080)
# Sets the description in 'help'
runner.description = "This is myapp"
# Setup custom 'test' option flag
runner.with_options do |opts|
  opts.on("-t", "--test TEST", String, "Test this thing") do |test|
    options[:test] = test
  end
end
# Create validation hook for options
runner.verify_options_hook = lambda { |opts|
  raise Exception.new("Must supply test parameter") if opts[:test].nil?
}
# Parse command-line options and execute the process
runner.execute do |opts|
  # opts: host, pid_path, port, daemonize, user, group
  Thin::Server.start('0.0.0.0', opts[:port]) do
    puts opts[:test] # Referencing my custom option
    use Rack::CommonLogger
    use Rack::ShowExceptions
    run MyApp
  end
end
```

Now you would be able to do:

```
./bin/myapp -t custom
```

and the `opts` would contain the `:test` option for use in your script. In addition, help will now contain
your customized description in the banner.

You can also use dante programmatically to start, stop and restart arbitrary code:

```ruby
# daemon start
Dante::Runner.new('gitdocs').execute(:daemonize => true, :pid_path => @pid, :log_path => @log_path) { something! }
# daemon stop
Dante::Runner.new('gitdocs').execute(:kill => true, :pid_path => @pid)
# daemon restart
Dante::Runner.new('gitdocs').execute(:daemonize => true, :restart => true, :pid_path => @pid) { something! }
```

so you can use dante as part of a more complex CLI executable.

## systemd

Under systemd, let systemd run the process in the foreground (`Type=simple`), as the user it names, with the
output going to the journal:

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=myapp
After=network.target

[Service]
Type=simple
User=myapp
Group=myapp
ExecStart=/path/to/myapp/bin/myapp -p 8080
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

systemd stops it with SIGTERM, which dante handles. To have dante daemonize instead, use `Type=forking` with the
pid file and the log in directories systemd creates for that user:

```ini
[Service]
Type=forking
User=myapp
Group=myapp
RuntimeDirectory=myapp
LogsDirectory=myapp
PIDFile=/run/myapp/myapp.pid
ExecStart=/path/to/myapp/bin/myapp -d -p 8080 -P /run/myapp/myapp.pid -l /var/log/myapp/myapp.log
Restart=on-failure
```

Use `User=` and `Group=` rather than `-u` and `-G` under systemd, so that the process starts as that user and the
directories systemd creates belong to it.

## Log rotation

The daemon opens its log file once, for appending, and has no SIGHUP handler: SIGHUP stops it. So rotate the log
with logrotate's `copytruncate`, rather than a `postrotate` script that sends SIGHUP:

```
# /etc/logrotate.d/myapp
/var/log/myapp/myapp.log {
  weekly
  rotate 4
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
```

`copytruncate` copies the log and empties it in place, and the daemon carries on writing at the start of the
emptied file. Lines written between the copy and the truncation are lost.

## God

Dante can be used well in conjunction with the excellent God process manager. Simply, use Dante to daemonize a process
and then you can easily use God to monitor:

```ruby
# /etc/god/myapp.rb

God.watch do |w|
  w.name            = "myapp"
  w.interval        = 30.seconds
  w.start           = "ruby /path/to/myapp/bin/myapp -d"
  w.stop            = "ruby /path/to/myapp/bin/myapp -k"
  w.start_grace     = 15.seconds
  w.restart_grace   = 15.seconds
  w.pid_file        = "/var/run/myapp.pid"

  w.behavior(:clean_pid_file)

  w.start_if do |start|
    start.condition(:process_running) do |c|
      c.interval = 5.seconds
      c.running = false
    end
  end
end
```

and that's all. Of course now you can also easily daemonize as well as start/stop the process on the command line as well.

## Copyright

Copyright © 2011-2026 Nathan Esquenazi. See [LICENSE](https://github.com/nesquena/dante/blob/master/LICENSE) for details.
