# Dante

Turn any process into a daemon with ease.

## Why Dante?

Dante is the simplest possible thing that will work to turn arbitrary ruby code into an executable that
can be started via command line or start/stop a daemon, and will store a pid file for you.

If you need to create a ruby executable and you want standard daemon start/stop with pid files
and no hassle, this gem will be a great way to get started.

## Installation

Add to your Gemfile:

```ruby
# Gemfile

gem "dante"
```

## Usage

Dante is meant to be used from any "bin" executable. For instance, to create a binary for a web server, create a file in `bin/mysite`:

```ruby
#!/usr/bin/env ruby

require File.expand_path("../../myapp.rb", __FILE__)

Dante.run('myapp') do
  Thin::Server.start('0.0.0.0', port) do
    use Rack::CommonLogger
    use Rack::ShowExceptions
    run MyApp
  end
end
```

This gives your binary several useful things for free:

```
./bin/myapp
```

will start the app undaemonized in the terminal, handling trapping and stopping the process.

```
./bin/myapp -d -P /var/run/myapp.pid
```

will daemonize and start the process, storing the pid in the specified pid file.

```
./bin/myapp -k -P /var/run/myapp.pid
```

will stop all daemonized processes for the specified pid file.

```
./bin/myapp --help
```

Will return a useful help banner message explaining the simple usage.

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

Copyright © 2011 Nathan Esquenazi. See [LICENSE](https://github.com/bazaarlabs/dante/blob/master/LICENSE) for details.