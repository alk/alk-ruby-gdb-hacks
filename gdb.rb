#!/usr/bin/env ruby

require 'tempfile'
require 'socket'
require 'pp'

module GDB
  def process_gdb_output 
    begin
      line = begin
               self.readpartial(65536)
             rescue EOFError
               return
             end
      exit = (line =~ /^\(gdb\)\s+/)
      if exit
        line = $`
      end
      yield line
    end while !exit
  end
  def eat_gdb_output
    process_gdb_output {|dummy| }
  end
  def command(cmd)
    silent = false
    cmd = cmd.strip
    if cmd[0] == ?@
      silent = true
      cmd = cmd[1..-1]
    end
    self.puts cmd
    process_gdb_output do |line|
      unless silent
        STDOUT.print line
        STDOUT.flush
      end
    end
  end

  def self.with_gdb
    IO.popen("gdb","r+") do |f|
      f.extend GDB
      f.eat_gdb_output

      yield f
    end
  end

  def self.print_backtrace_of_pid(pid)
    tmp = Tempfile.new("backtrace")
    path = tmp.path
    tmp.close
    with_gdb do |f|
      script = <<HERE
@set pagination off
@attach #{pid}
@set $newfd = open(#{path.inspect}, #{IO::WRONLY|IO::CREAT}, 0600)
@set $newstdout = dup(1)
@call dup2($newfd, 1)
@call close($newfd)
@call rb_backtrace()
@call rb_funcall(rb_funcall(rb_mKernel, rb_intern("const_get"), 1, rb_str_new2("STDOUT")), rb_intern("flush"), 0)
@call dup2($newstdout, 1)
@call close($newstdout)
@quit
HERE
      script.split(%r{\n}).each {|c| f.command c}
    end
    print IO.read(path)
    File.unlink(path)
  end

  def self.set_nodelay(pid, fd)
    with_gdb do |f|
      script = <<HERE
@set pagination off
@attach #{pid}
@set $old_errno = errno
@set $flag = (int *)malloc(4)
@set *($flag) = 1
p setsockopt(#{fd}, #{Socket::IPPROTO_TCP}, #{Socket::TCP_NODELAY}, $flag, 4)
set errno = $old_errno
@quit
HERE
      script.split(/\n/).each {|c| f.command c}
    end
  end

  def self.force_socket_nodelay(my_side)
    my_side.setsockopt Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1

    raw_output = `lsof -n | grep -- '->127.0.0.1:#{my_side.addr[1]}'`.split(/\s+/)
    pid, fd = raw_output[1].to_i, raw_output[3].to_i

    set_nodelay(pid, fd)
  end
end

if __FILE__ == $0
  pid = ARGV[0] || raise("need PID")

  if pid == "--mongrels"
    puts "Printing backtraces of all mongrels"
    all_pids = Dir[File.expand_path(File.dirname(__FILE__)+"/../log/mongrel*.pid")].map do |path|
      [File.basename(path), IO.read(path).strip]
    end
    all_pids.each do |basename, pid|
      puts "Backtrace of #{basename} (#{pid}):"
      GDB.print_backtrace_of_pid pid
      puts "----------------------"
    end
  else
    GDB.print_backtrace_of_pid pid
  end
end
