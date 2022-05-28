#!/usr/bin/env ruby
#--
# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/sonic-pi-net/sonic-pi
# License: https://github.com/sonic-pi-net/sonic-pi/blob/main/LICENSE.md
#
# Copyright 2021 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, and
# distribution of modified versions of this work as long as this
# notice is included.
#++

require 'socket'
require 'shellwords'
require 'open3'
require 'fileutils'
require 'time'
require 'securerandom'

require_relative "../lib/sonicpi/osc/osc"
require_relative "../lib/sonicpi/promise"


# Make sure vendored tomlrb lib is on the Ruby path so it can be required
Dir["#{File.expand_path("../../vendor", __FILE__)}/*/lib/"].each do |vendor_lib|
  $:.unshift vendor_lib
end

require 'tomlrb'
require_relative '../paths'

Thread::abort_on_exception = true

# The Sonic Pi Boot Daemon.
# =========================
#
# Process Spawning
# ----------------
#
# The Daemon launches and watches over the following long-living
# processes (necessary for Sonic Pi to work):
#
#   +--> Tau     - the Erlang IO server
#   +--> Scsynth - the SuperCollider audio engine
#   +--> Spider  - the Ruby Runtime server
#
# The Daemon does all the work necessary to figure out the correct
# process paths and flags - even considering config files such as
# `audio-settings.toml and tau-settings.toml`
#
#
# Zombie Kill Switch
# ------------------
#
# It is the Daemon's responsibility to ensure that the processes it
# boots are always terminated and are not left to turn into zombies and
# stick around continuing to accidentally run on your computer consuming
# resources.
#
# This is achieved via a "Zombie Kill Switch" - a UDP connection with an
# external process (such as the GUI) to monitor its status by
# continually receiving keep_alive messages. If these messages stop
# being received (for example, if the GUI process exited normally or
# even crashed) then the Daemon will ensure all the processes it spawned
# (Spider, Tau and Scsynth) are terminated.
#
# The port number of this kill switch UDP connection is printed to
# STDOUT. A external process (such as the GUI) must connect promptly and
# periodically send an OSC message with the path /daemon/keep-alive (more
# frequently than every 3s) otherwise a timeout will trigger the kill
# switch and kill all the spawned processes.
#
# If the client wants to explicitly trigger the kill switch directly
# rather than via a timeout it can send an OSC message with path
# /daemon/exit along with a single integer argument which is the comms
# token (also printed to STDOUT - see below).
#
#
# Port Allocations & Comms Token
# ------------------------------
#
# The Daemon figures out appropriate (and currently free) values for all
# the ports used by various processes within Sonic Pi to communicate
# with each other. These ports are used to create the correct process
# arguments for spawning and are also passed to STDOUT.
#
# Some of these port numbers need to be known by the client process
# so that it can both send code to run and receive log updates via UDP.
#
# The final value printed to stdout is the comms token which is a random
# 32 bit signed integer. This must be used as the first argument to all
# OSC messages sent from the GUI to Daemon such as: /daemon/keep-alive
# and /daemon/exit.
#
# The current allocations of these external port numbers are printed to
# STDOUT in the following order:
#
# daemon-keep-alive gui-listen-to-server gui-send-to-server scsynth osc-cues tau-api tau-phx token
#
#
# Stdout Parameter Descriptions
# -----------------------------
#
# daemon:               UDP port Daemon is listening on. This is used for
#                       receiving /daemon/keep-alive OSC messages amongst
#                       other things.
#
# gui-listen-to-server: UDP port which the GUI uses to listen to messages
#                       from the Spider Server.
#
# gui-send-to-server:   UDP port which the GUI uses to send messages to
#                       the Spider Server.
#
# scsynth:              UDP port on which scsynth listens (necessary for
#                       connecting to the boost shared memory for scope data)
#
# osc-cues:             UDP port used to receive OSC cue messages from external
#                       processes.
#
# tau-api:              UDP port used to send OSC messages to trigger the
#                       Tau API
#
# tau-phx:              HTTP port used by Tau's Phoenix web server
#
#
# token:                32 bit signed integer used as a token to authenticate
#                       OSC messages.  All OSC messages sent from the GUI
#                       must include this token as the first argument


module SonicPi
  module Daemon
    class Init

      def initialize
        @exit_prom = Promise.new
        @restart_tau_mut = Mutex.new
        @booting_tau = false

        @safe_exit = SafeExit.new do
          @exit_prom.deliver! true
          # Register exit routine
          # This will only be called once
          Util.log "Daemon Booter is now exiting."
          Util.log "Cleaning up any running processes..."
          cleanup_any_running_processes
          Util.log "Daemon Booter - Over and Out."
          Util.close_log
        end

        # This is where the Daemon begins and ends.

        @scsynth_booter  = nil
        @tau_booter      = nil
        @spider_booter   = nil

        # use a value within the valid range for a 32 bit signed complement integer
        @daemon_token =  rand(-2147483647..2147483647)

        Util.open_log
        Util.log "Welcome to the Daemon Booter"

        # don't worry if there's a problem clearing the logs.
        begin
          clear_logs
        rescue StandardError => e
          Util.log "Non-critical error clearing logs"
          Util.log_error(e)
        end

        # Get a map of port numbers to use
        #
        # Note that the program will safe_exit here
        # if there are problems detecting port numbers to use.
        @ports = PortDiscovery.new(@safe_exit).ports

        Util.log "Selected ports: "
        Util.log @ports.inspect

        @kill_switch = KillSwitch.new(@safe_exit)

        boot_tau!(false)

        @api_server = SonicPi::OSC::UDPServer.new(@ports["daemon"], suppress_errors: false, name: "Daemon API Server")
        # For debugging purposes:
        # @api_server = SonicPi::OSC::UDPServer.new(@ports["daemon"], suppress_errors: false, name: "Daemon API Server") do |address, args, sender_addrinfo|
        #   Util.log "Kill switch ##{@ports["daemon"] Received UDP data #{[address, args, sender_addrinfo].inspect}"
        # end

        @api_server.add_method("/daemon/keep-alive") do |args|
          if args[0] && args[0] == @daemon_token
            @kill_switch.keep_alive!
          end
        end

        @api_server.add_method("/daemon/exit") do |args|
          if args[0] && args[0] == @daemon_token
            Util.log "[EXIT] Kill switch for port #{@ports["daemon"]} remotely activated using token #{@daemon_token}"
            @safe_exit.exit
          else
            Util.log "Kill switch for port #{@ports["daemon"]} received incorrect token. Ignoring #{args[0]}"
          end
        end

        @api_server.add_method("/daemon/restart-tau") do |args|
          if args[0] && args[0] == @daemon_token
            Util.log "Restarting Tau"
            restart_tau!
          end
        end

        @api_server.add_method("/tau/pid") do |args|
          Util.log "Daemon received Pid from Tau: #{args.inspect}"
          # Util.log "token: #{@daemon_token}"
          if args[0] && args[0] == @daemon_token
            @tau_booter.update_pid!(args[1])
          end
        end

        # Let the calling process (likely the GUI) know which port to
        # listen to and communicate on with the Ruby spider server via
        # STDOUT.
        puts "#{@ports["daemon"]} #{@ports["gui-listen-to-spider"]} #{@ports["gui-send-to-spider"]} #{@ports["scsynth"]} #{@ports["osc-cues"]} #{@ports["tau"]} #{@tau_booter.phx_port} #{@daemon_token}"

        Util.log "#{@ports["daemon"]} #{@ports["gui-listen-to-spider"]} #{@ports["gui-send-to-spider"]} #{@ports["scsynth"]} #{@ports["osc-cues"]} #{@ports["tau"]} #{@tau_booter.phx_port} #{@daemon_token}"

        STDOUT.flush

        Util.log "Booting Scsynth"
        @scsynth_booter = ScsynthBooter.new(@ports)

        Util.log "Booting Spider Server"
        @spider_booter  = SpiderBooter.new(@ports, @daemon_token)

        Util.log "Blocking main thread until exit signal received..."
        begin
          @exit_prom.get
          Util.log "Exit signal received..."
        rescue
          # Way Out
        end
      end

      def boot_tau!(wait_for_pid = true)
        @booting_tau = true
        Util.log "Booting Tau..."
        begin
          @tau_booter = TauBooter.new(@ports, @kill_switch, @daemon_token)
          @tau_booter.wait_for_pid! if wait_for_pid
          @booting_tau = false
        rescue StandardError => e
          Util.log "Oh no, something went wrong booting Tau"
          Util.log_error(e)
          puts "Oh no, something went wrong booting Tau"
          puts "Error Class: #{e.class}"
          puts "Error Message: #{e.message}"
          puts "Error Backtrace: #{e.backtrace.join("\n")}"
          puts 'hi'
          STDOUT.flush
          @safe_exit.exit
        end
      end

      def restart_tau!
        return if @booting_tau
        Thread.new do
          @restart_tau_mut.synchronize do
            return if @booting_tau
            @booting_tau = true
            Util.log "Restarting Tau..."
            @tau_booter.kill
            boot_tau!
          end
        end
      end

      def cleanup_any_running_processes
        [@spider_booter, @scsynth_booter, @tau_booter].map do |p|
          Thread.new do
            begin
              p.kill if p
            rescue StandardError => e
              Util.log "Error attempting to kill process #{p.inspect}"
              Util.log_error(e)
            end
          end
        end.each { |t| t.join }
      end


      # Copy contents of current logs to a rotating
      # backup directory and clear ready for a new
      # run.
      #
      # TODO: Handle the case where the log path isn't writable.
      def clear_logs
        Util.log "Clearing logs"
        # ensure this list matches set of expected log files should more services/aspects be similarly logged.
        expected_logs = [
          "daemon.log",
          "debug.log",
          "gui.log",
          "scsynth.log",
          "spider.log",
          "tau.log"]

        # Windows doesn't allow certain chars in file paths
        # which are present in the default Time.now string format.
        # therefore remove them.
        sanitised_time_str = Time.now.to_s.gsub!(/[^0-9a-zA-Z-]/, '_')
        history_dir = File.absolute_path("#{Paths.log_history_path}/#{sanitised_time_str}")
        Util.log "Storing previous log files into #{history_dir}"
        FileUtils.mkdir_p(history_dir)

        Dir["#{Paths.log_path}/*.log"].each do |p|
          FileUtils.cp(p, "#{history_dir}/")
          # Copy log to history directory
          if expected_logs.include?(File.basename(p))
            # (don't remove the expected log files, just empty them)
            File.open(p, 'w') {|file| file.truncate(0) }
          else
            begin
              FileUtils.rm p
            rescue
            end
          end
        end

        # clean up old history logs
        # only store the last 10 sessions
        num_sessions_to_store = 10

        history_dirs = Dir.glob("#{Paths.log_history_path}/*")

        begin
          history_dirs = history_dirs.sort {|d| File.birthtime(d) }
        rescue
          nil
        end

        Util.log "history dirs timestamps: #{history_dirs.inspect}"
        num_history_dirs = history_dirs.size
        num_to_drop = num_history_dirs - num_sessions_to_store

        if num_to_drop.positive?
          history_dirs.take(num_to_drop).each do |dir_path|
            FileUtils.rm_rf(dir_path)
          end
        end
      end
    end


    module Util
      def self.open_log
        begin
          @@log_file = File.open(Paths.daemon_log_path, 'a')
        rescue StandardError => e
          STDERR.puts "Unable to open log file #{Paths.daemon_log_path}"
          STDERR.puts e.inspect
          STDERR.puts "----\n\n"
          @@log_file = nil
        end
      end

      def self.close_log
        @@log_file.close if @@log_file
      end

      def self.timestamp_for_log
        "[#{Time.now.strftime("%Y-%m-%d %H:%M:%S")}]"
      end

      def self.log(msg)
        begin
          if @@log_file
            @@log_file.puts("#{timestamp_for_log} #{msg}")
            @@log_file.flush
          end
        rescue IOError => e
          STDERR.puts "Error. Unable to write to log file: #{e.message}"
          STDERR.puts e.inspect
        end
      end

      def self.log_error(e)
        spacer = "\n " + (" " * timestamp_for_log.size)
        log "#{e.class}"
        log "#{e.message}"
        log "##{e.backtrace.join(spacer)}"
      end

      def self.os
        case RUBY_PLATFORM
        when /.*arm.*-linux.*/
          :raspberry
        when /aarch64.*linux.*/
          :raspberry
        when /.*linux.*/
          :linux
        when /.*darwin.*/
          :macos
        when /.*mingw.*/
          :windows
        else
          raise "Unsupported platform #{RUBY_PLATFORM}"
        end
      end
    end

    class KillSwitch
      def initialize(safe_exit)
        @safe_exit = safe_exit
        @kill_switch_prom = Promise.new
        @queue = Queue.new

        activate

        @timer_thread = Thread.new do
          attempts = 0
          max_attempts = 4
          Kernel.sleep 40
          loop do
            Kernel.sleep 10
            if @queue.empty?
              attempts += 1
            else
              attempts = 0
              @queue.clear
            end

            break if attempts > max_attempts
          end
          Util.log "Kill switch timed out..."
          @kill_switch_prom.deliver!(true)
        end
      end

      def keep_alive!
        @queue << true
      end

      def wait
        @kill_switch_prom.get
      end

      def activate
        return if @armed_thread
        @armed_thread = Thread.new do
          wait
          Util.log "[EXIT] Daemon kill switch triggered. Exiting..."
          @timer_thread.kill
          @safe_exit.exit
        end
      end

      def deactivate
        @armed_thread.kill
      end
    end

    class SafeExit

      def initialize(&cleanup_procedure)

        @exit_mut               = Mutex.new
        @exit_cleanup_mut       = Mutex.new
        @exit_in_progress       = false
        @exit_cleanup_completed = false
        @cleanup_procedure      = cleanup_procedure

        at_exit do
          Util.log "[EXIT] Daemon Process has completed:"

          @exit_mut.synchronize do
            @exit_in_progress = true
            idempotent_exit_cleanup
          end
        end
      end

      def exit
        Thread.current.kill if @exit_in_progress

        @exit_mut.synchronize do
          if @exit_in_progress
            Thread.current.kill
          else
            @exit_in_progress = true
            idempotent_exit_cleanup
            Kernel.exit
          end
        end
      end

      private

      def idempotent_exit_cleanup
        @exit_cleanup_mut.synchronize do
          unless @exit_cleanup_completed
            @cleanup_procedure.call
            @exit_cleanup_completed = true
          end
        end
      end
    end

    class ProcessBooter
      attr_reader :pid, :args, :cmd
      def initialize(cmd, args, log_path)
        @pid = nil
        @log_file = nil
        @args = args.map {|el| el.to_s}
        @cmd = cmd
        if log_path
          begin
            @log_file = File.open(log_path, 'a')
          rescue StandardError => e
            STDERR.puts "Unable to open log file #{log_path}"
            STDERR.puts e.inspect
            STDERR.puts "----\n\n"
            @log_file = nil
          end
        end

        begin
          boot
        rescue StandardError => e
          Util.log "Error: something went wrong booting process: #{cmd}, #{args}, #{log_path}"
          Util.log_error(e)
          @log_file.close if @log_file
        end
      end

      def inspect
        "<ProcessBooter - cmd: #{@cmd}, pid: #{@pid.inspect}, args: #{@args.inspect}>"
      end

      def boot
        Util.log "Process Booter - booting #{@cmd} with args #{@args.inspect}"
        Util.log "#{@cmd} #{@args.join(' ')}"
        @stdin, @stdout_and_err, @wait_thr = Open3.popen2e @cmd, *@args
        @pid = @wait_thr.pid
        if @log_file
          @io_thr = Thread.new do
            @stdout_and_err.each do |line|
              begin
                @log_file << line
                @log_file.flush
              rescue IOError
                # don't attempt to write
              end
            end
          end
        end
      end

      def process_running?
        return false unless @wait_thr
        @wait_thr.status
      end

      def wait
        begin
          @wait_thr.join if @wait_thr
        rescue Interrupt => e
          Util.log "Got interrupted waiting for #{@cmd} to complete"
        end
      end

      def kill
        if process_running? && @pid
          Util.log "Process Booter - killing #{@cmd} with pid #{@pid} and args #{@args.inspect}, wait_thr status: #{@wait_thr}, #{@wait_thr.status}"

          unless Util.os == :windows
            begin
              Util.log "Sending TERM kill command to #{@pid.inspect}"
              Process.kill("TERM", @pid)
            rescue Errno::ESRCH
              Util.log "Unable to send TERM kill command to #{@pid.inspect} as it's no longer running"
            end

            countdown = 5

            while process_running? && countdown >= 0
              Util.log "Process #{@pid.inspect} still running, waiting for it to finish... [#{countdown}]"
              sleep 1
              countdown -= 1
            end
          end

          if process_running?

            # We're either running on Windows (which doesn't seem to
            # support SIGTERM) or we attempted to kill the process nicely,
            # but unfortunately that didn't work, so let's forcefully kill
            # it
            begin
              Util.log "Sending KILL kill command to #{@pid.inspect}"
              Process.kill("KILL", @pid)
            rescue Errno::ESRCH
              Util.log "Unable to send KILL kill command to #{@pid.inspect} as it's no longer running"
            end

            countdown = 5

            while process_running? && countdown >= 0
              Util.log "Process #{@pid.inspect} still running, waiting for it to finish... [#{countdown}]"
              sleep 1
              countdown -= 1
            end
          end

          if process_running?
            Util.log "Unable to terminate process #{@pid.inspect}"
          else
            Util.log "Process #{@pid.inspect} terminated"
          end
        else
          Util.log "Process Booter - no need to kill #{@cmd} with pid #{@pid} and args #{@args.inspect} - already terminated, wait_thr status: #{@wait_thr}, #{@wait_thr.status}"
        end


        unless @pid
          Util.log "Process Booter - Unfortunately we don't have a @pid for  #{@cmd} with args #{@args.inspect}. wait_thr: #{@wait_thr}"
        end

        @io_thr.kill if @io_thr
        @log_file.close if @log_file

      end
    end

    class SpiderBooter < ProcessBooter
      def initialize(ports, token)
        args = [
          "--enable-frozen-string-literal", "-E", "utf-8",
          Paths.spider_server_path,
          "-u",
          ports["spider-listen-to-gui"],
          ports["spider-send-to-gui"],
          ports["scsynth"],
          ports["scsynth-send"],
          ports["osc-cues"],
          ports["tau"],
          ports["spider-listen-to-tau"],
          token
        ]

        super(Paths.ruby_path, args, Paths.spider_log_path)
      end
    end


    class TauBooter < ProcessBooter
      attr_reader :phx_port

      def initialize(ports, kill_switch, token)
        @tau_pid = Promise.new

        @pid_requester = SonicPi::OSC::UDPClient.new('localhost', ports["tau"])

        @pid_updater_thread = Thread.new do
          while !@tau_pid.delivered?
            Util.log "Requesting tau send us its pid. Sending /send-pid-to-daemon, #{token} to localhost:#{ports['tau']}"
            begin
              @pid_requester.send("/send-pid-to-daemon", token)
            rescue Errno::ECONNREFUSED
              Util.log "Error talking to Tau - connection refused (perhaps Tau is still booting?)"
            rescue StandardError => e
              Util.log "Error talking to Tau"
              Util.log_error(e)
            end
            Kernel.sleep 1
          end
        end


        begin
          Util.log "fetching toml opts"
          toml_opts_hash = Tomlrb.load_file(Paths.user_tau_settings_path, symbolize_keys: true).freeze
          Util.log "got them: #{toml_opts_hash}"
          unified_opts = unify_tau_toml_opts(toml_opts_hash)
          Util.log "unified them: #{unified_opts}"
        rescue StandardError
          unified_opts = {}
        end

        cues_on                        = true
        osc_in_udp_loopback_restricted = false
        midi_on                        = true
        link_on                        = true
        osc_in_udp_port                = ports["osc-cues"]
        api_port                       = ports["tau"]
        spider_port                    = ports["spider-listen-to-tau"]
        daemon_port                    = ports["daemon"]
        midi_enabled                   = true
        link_enabled                   = true
        phx_secret_key_base            = SecureRandom.base64(64)
        env                            = ENV["SONIC_PI_ENV"] || unified_opts[:env] || "prod"
        @phx_port                      = unified_opts[:phx_port] || ports["phx"]

        Util.log "Daemon listening to info from Tau on port #{daemon_port}"



        args = [
          cues_on,
          osc_in_udp_loopback_restricted,
          midi_on,
          link_on,
          osc_in_udp_port,
          api_port,
          spider_port,
          daemon_port,
          Paths.tau_log_path,
          midi_enabled,
          link_enabled,
          phx_port,
          phx_secret_key_base,
          token,
          env
        ]

        if Util.os == :windows
          cmd = Paths.mix_release_boot_path
        else
          cmd = "sh"
          args = [Paths.mix_release_boot_path] + args
        end

        super(cmd, args, nil)
      end

      def restart!
        @tau_pid = Promise.new
      end

      def update_pid!(pid)
        @tau_pid.deliver!(pid, false)
      end

      def wait_for_pid!()
        @tau_pid.get(30)
      end

      def unify_tau_toml_opts(opts)
        unified_opts = {}

        # env should be either "dev" or "prod"
        case opts[:env].to_s.downcase.strip
        when "dev"
          unified_opts[:env] = "dev"
        when "prod"
          unified_opts[:env] = "prod"
        end

        # phx_port should be a positive integer
        begin
          phx_port = opts[:phx_port].to_i
          unified_opts[:phx_port] = phx_port if phx_port > 0
        rescue
          # do nothing
        end

        unified_opts.freeze
      end

      def kill
        begin
          @pid = @tau_pid.get(30)
          Util.log "Killing Tau with pid #{@pid.inspect}"
        rescue SonicPi::PromiseTimeoutError
          @pid = nil
          Util.log "Didn't receive Tau's Pid after waiting for 30s..."
        end
        super
      end
    end


    class JackBooter < ProcessBooter
      def initialize
        cmd = "jackd"
        args = ["-T", "-d", "dummy", "-r", "48000", "-p", "1024"]
        super(cmd, args, Paths.jackd_log_path)
      end
    end


    class ScsynthBooter < ProcessBooter

      DEFAULT_OPTS = {
        "-a" => "1024",
        "-m" => "131072",
        "-D" => "0",
        "-R" => "0",
        "-l" => "1",
        "-i" => "16",
        "-o" => "16",
        "-b" => "4096",
        "-B" => "127.0.0.1" }.freeze

      OS_SPECIFIC_OPTS =
        case Util.os
        when :raspberry
          {
          "-c" => "128",
          "-z" => "128",
          "-i" => "2",
          "-o" => "2",
          "-U" => Paths.scsynth_raspberry_plugin_path
        }.freeze
        when :windows
          {
          "-U" => Paths.scsynth_windows_plugin_path
        }.freeze
        else
          {
        }.freeze
        end

      OPTS_TOML_KEY_CONVERSION = {
        sound_card_name:          "-H",
        sound_card_sample_rate:   "-S",
        sound_card_buffer_size:   "-Z",
        num_inputs:               "-i",
        num_outputs:              "-o",
        block_size:               "-z",
        enable_inputs:            "-I",
        enable_outputs:           "-O",
        num_control_bus_channels: "-c",
        num_audio_bus_channels:   "-a",
        num_sample_buffers:       "-b",
        max_num_nodes:            "-n",
        max_num_synthdefs:        "-d",
        real_time_memory_size:    "-m",
        num_wire_buffers:         "-w",
        num_random_seeds:         "-r"
      }.freeze


      def initialize(ports)
        @port = ports["scsynth"]
        begin
          toml_opts_hash = Tomlrb.load_file(Paths.user_audio_settings_path, symbolize_keys: true).freeze
        rescue StandardError => e
          Util.log "---- Audio Config Issue ----"

          if !File.exist? Paths.user_audio_settings_path
            Util.log "Could not find #{Paths.user_audio_settings_path} - reverting to default audio options."
          else
            Util.log "Issue reading #{Paths.user_audio_settings_path}:"
            Util.log_error(e)
          end
          Util.log "This is not critical - reverting to default audio options"
          Util.log "----------------------------"
          toml_opts_hash = {}
        end

        opts = unify_toml_opts_hash(toml_opts_hash)
        opts = merge_opts(opts)
        @num_inputs = opts["-i"].to_i
        @num_outputs = opts["-o"].to_i
        args = opts.to_a.flatten
        cmd = Paths.scsynth_path
        run_pre_start_commands
        super(cmd, args, Paths.scsynth_log_path)
        run_post_start_commands
      end

      def kill
        @jack_booter.kill if @jack_booter
        super
      end

      def run_pre_start_commands
        case Util.os
        when :linux, :raspberry
          #Start Jack if not already running
          if `jack_wait -c`.include? 'not running'
            #Jack not running - start a new instance
            Util.log "Jackd not running on system. Starting..."
            @jack_booter = JackBooter.new
          else
            Util.log "Jackd already running. Not starting another server..."
          end
        end
      end

      def run_post_start_commands
        case Util.os
        when :linux, :raspberry
          Thread.new do
            Kernel.sleep 5
            # Note:
            # need to modify this to take account for @num_inputs and @num_outputs.
            # These might not always be set to two channels each.
            if @jack_booter
              #First clear up any pulseaudio remains of module-loopback source=jack_in
              `pactl list short modules |grep source=jack_in| cut -f1 | xargs -L1 pactl unload-module`
              `pactl load-module module-jack-source channels=2 connect=0 client_name=JACK_to_PulseAudio`
              `pactl load-module module-loopback source=jack_in`
              `pactl load-module module-jack-sink channels=2 connect=0 client_name=PulseAudio_to_JACK`
              `jack_connect PulseAudio_to_JACK:front-left SuperCollider:in_1`
              `jack_connect PulseAudio_to_JACK:front-right SuperCollider:in_2`
              `jack_connect SuperCollider:out_1 JACK_to_PulseAudio:front-left`
              `jack_connect SuperCollider:out_2 JACK_to_PulseAudio:front-right`
            else
              `jack_connect SuperCollider:out_1 system:playback_1`
              `jack_connect SuperCollider:out_2 system:playback_2`
              `jack_connect SuperCollider:in_1 system:capture_1`
              `jack_connect SuperCollider:in_2 system:capture_2`
            end
          end
        end
      end


      def unify_toml_opts_hash(toml_opts_hash)
        opts = {}

        toml_opts_hash.each do |k, v|
          v = case v
              when TrueClass
                1
              when FalseClass
                0
              when String
                v.strip
              else
                v
              end

          command_line_key = OPTS_TOML_KEY_CONVERSION[k.to_sym]
          val = v.to_s

          #raise "Unknown SuperCollider scsynth arg: #{k}. Expected one of #{OPTS_TOML_KEY_CONVERSION.keys.inspect}" unless command_line_key
          next unless command_line_key

          opts[command_line_key] = val
        end
        opts
      end

      def merge_opts(opts)
        # extract scsynth opts override
        begin
          clobber_opts_a = Shellwords.split(opts.fetch(:scsynth_opts_override, ""))
          scsynth_opts_override = clobber_opts_a.each_slice(2).to_h
        rescue
          scsynth_opts_override = {}
        end

        # extract scsynth opts
        begin
          scsynth_opts_a = Shellwords.split(opts.fetch(:scsynth_opts, ""))
          scsynth_opts = scsynth_opts_a.each_slice(2).to_h
        rescue
          scsynth_opts = {}
        end


        if scsynth_opts_override.empty?
          merged_opts = {"-u" => @port}.merge(DEFAULT_OPTS).merge(OS_SPECIFIC_OPTS).merge(opts).merge(scsynth_opts)

          # reduce number of inputs to 0 if inputs are disabled
          merged_opts["-i"] = 0 if merged_opts["-I"] == "0"

          # reduce number of outputs to 0 if outputs are disabled
          merged_opts["-o"] = 0 if merged_opts["-O"] == "0"

          return merged_opts
        else
          return scsynth_opts_override
        end
      end
    end

    class PortDiscovery
      attr_reader :ports

      # Change these values to alter the ports
      # Sonic Pi uses to send and receive messages at run time:
      PORT_CONFIG = {
        # Port daemon uses to communicate with GUI or other controlling process
        "daemon" => :dynamic,

        # Port which the server uses to listen to messages from the GUI:
        "spider-listen-to-gui" => :dynamic,

        # Port which the GUI uses to send messages to the server:
        # May be paired with server_listen_to_gui
        "gui-send-to-spider" => :paired,

        # Port which the GUI uses to listen to messages from the server:
        "gui-listen-to-spider" => :dynamic,

        # Port which the server uses to send messages to the GUI:
        # May be paired with :gui_listen_to_server
        "spider-send-to-gui" => :paired,

        # Port which the SuperCollider server scsynth listens to:
        # (scsynth will automatically send replies back to the port
        # from which the message originated from)
        "scsynth" => :dynamic,

        # Port which the server uses to send messages to scsynth
        # May be paired with scsynth
        "scsynth-send" => :paired,

        # Port which the server uses to listen to messages which
        # will automatically be converted to cue events:
        "osc-cues" => 4560,

        # Port which the Tau listens to.
        "tau" => :dynamic,

        # Port which the Ruby server listens to messages back from the Tau server
        "spider" => :dynamic,

        "daemon-listen-to-tau" => :dynamic,
        "spider-listen-to-tau" => :dynamic,

        # Port which the Phoenix webserver runs on
        "phx" => :dynamic
      }.freeze

      def initialize(safe_exit)
        @safe_exit = safe_exit
        # choose random port to try first
        @last_free_port = 29152 + rand(10000).to_i

        @ports = [
          # each entry is the name of a port to determine.
          # pairs of entry-names represent pairings where
          # the first element will default to the second
          # when its value is set to :paired
          "spider-listen-to-gui",
          ["gui-send-to-spider","spider-listen-to-gui"],

          "gui-listen-to-spider",
          ["spider-send-to-gui", "gui-listen-to-spider"],

          "scsynth",
          ["scsynth-send", "scsynth"],

          "osc-cues",
          "tau",
          "spider",
          "phx",
          "daemon",
          "spider-listen-to-tau"].inject({}) do |res, port_name|

          default = nil
          case port_name
          when Array
            default = PORT_CONFIG[port_name[0]]
            if default == :dynamic
              port = find_free_port
            elsif default == :paired
              port = res[port_name[1]]
            else
              if check_port(default)
                port = default
              else
                port = find_free_port
              end
            end
            res[port_name[0]] = port.to_i
          else
            default = PORT_CONFIG[port_name]
            if default == :dynamic
              port = find_free_port
            elsif default == :paired
              Util.log "[EXIT] Invalid port default for port: #{port_name}. This port can not be paired."
              @safe_exit.exit
            else
              port = default
              if(!check_port(port))
                port = find_free_port
              end
            end
            res[port_name] = port.to_i
          end

          res
        end
      end

      def check_port(port)
        available = false
        begin
          socket = UDPSocket.new
          socket.bind('127.0.0.1', port)
          Util.log "checked port #{port}, #{socket}"
          socket.close
          available = true
        rescue StandardError
          available = false
        end
        available
      end

      def find_free_port
        while !check_port(@last_free_port += 1)
          if @last_free_port > 65535
            Util.log "[EXIT] Unable to find a free port."
            @safe_exit.exit
          end
        end
        @last_free_port
      end
    end
  end
end

begin
  SonicPi::Daemon::Init.new
rescue StandardError => e
  SonicPi::Daemon::Util.log "[BUG] - ** Daemon Internal Error. **"
  SonicPi::Daemon::Util.log_error(e)
end
