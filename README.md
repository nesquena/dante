Dante
=====

Turn any ruby loop into a daemon.

Dante is the simplest possible thing that will work to turn arbitrary ruby code into an executable that
can be started via command line or start/stop a daemon, and will store a pid file for you.

If you need to create a ruby executable and you want standard daemon start/stop with pid files
and no hassle, this gem will be a great way to get started.

Installing
----------

Using
-----

Dante is meant to be used from any "bin" executable.
For instance, to create a binary for a web server, create a file in `bin/myapp`:

``` ruby
#!/usr/bin/env ruby

require "dante"
require_relative "myapp"

Dante.run("myapp") do |parameters|
  Thin::Server.start(parameters.host, parameters.port) do
    use Rack::CommonLogger
    use Rack::ShowExceptions
    run MyApp
  end
end
```

For more advanced or dynamic setup:

``` ruby
require "dante"

program_name = "watcher"

program_command = Dante::Command.new do |command|
  command.on("-h", "--host", String, "Provide a server host") do |host|
    options[:host] = host
  end

  command.on("-p", "--port", String, "Provide a server port") do |port|
    options[:port] = port
  end
end

program_process = lambda do |parameters|
  Thin::Server.start(parameters.host, parameters.port) do
    use Rack::CommonLogger
    use Rack::ShowExceptions
    run MyApp
  end
end

program = Dante.new(program_name, program_command, program_process)
```

You can also setup

Be sure to properly make your bin executable:

``` shell
chmod +x bin/myapp
```


## Copyright

Copyright © 2011 Nathan Esquenazi. See [LICENSE](https://github.com/bazaarlabs/dante/blob/master/LICENSE) for details.
