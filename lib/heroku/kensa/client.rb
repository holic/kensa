require 'restclient'
require 'term/ansicolor'
require 'launchy'

module Heroku
  class Git
    class << self
      def verify_create(app_name, template)
        raise CommandInvalid.new("template #{clone_url(template)} does not exist") unless template_exists?(template)
        raise CommandInvalid.new("Need git to clone repository") unless git_installed?
      end

      def template_exists?(template)
        true
      end

      def git_installed?
        `git` rescue false
      end

      def clone(app_name, template)
        verify_create(app_name, template)
        cmd = "git clone #{clone_url(template)} #{app_name}" 
        puts cmd
        `#{cmd}`
        raise Exception.new("couldn't clone the repository from #{clone_url(template)}") unless File.directory?("#{app_name}")
        puts "Created #{app_name} from #{template} template"
      end

      def clone_url(name)
        prefix = ENV['REPO_PREFIX'] || "heroku"
        if name.include? "://"  #its a full url
          return name
        elsif name.include? "/" #its a non-heroku repo
          name = "#{prefix}/#{name}" 
        else                    #its one of ours 
          name = "#{prefix}/kensa-create-#{name}" 
        end

        "git://github.com/#{name}"
      end
    end
  end

  module Kensa
    class Client
      def initialize(args, options)
        @args    = args
        @options = options
      end

      def filename
        @options[:filename]
      end

      #you fucked up
      class CommandInvalid < Exception; end
      #we fucked up
      class CommandFailed  < Exception; end

      def run!
        command = @args.shift || @options[:command]
        raise CommandInvalid unless command && respond_to?(command)
        send(command)
      end

      def init
        Manifest.new(filename, @options).write
        Screen.new.message "Initialized new addon manifest in #{filename}\n"
      end

      def create
        app_name = @args.shift
        template = @options[:template]
        raise CommandInvalid.new("Need git to supply a template") unless template
        raise CommandInvalid.new("Need git to supply an application name") unless app_name

        begin
          Git.clone(app_name, template)
        rescue Exception => e
          raise CommandFailed.new("error cloning #{Git.clone_url(template)} into #{app_name}") 
        end

        Dir.chdir("./#{app_name}")
        `./after_clone #{app_name}` if File.exist?('./after_clone')
      end


      def test
        case check = @args.shift
          when "manifest"
            require "#{File.dirname(__FILE__)}/../../../test/manifest_test"
            require 'test/unit/ui/console/testrunner'
            $manifest = Yajl::Parser.parse(resolve_manifest)
            Test::Unit.run = true
            Test::Unit::UI::Console::TestRunner.new(ManifestTest.suite).start
          when "provision"
            require "#{File.dirname(__FILE__)}/../../../test/provision_test"
            require 'test/unit/ui/console/testrunner'
            $manifest = Yajl::Parser.parse(resolve_manifest)
            Test::Unit.run = true
            Test::Unit::UI::Console::TestRunner.new(ProvisionTest.suite).start
          when "deprovision"
            id = @args.shift || abort("! no id specified; see usage")
            require "#{File.dirname(__FILE__)}/../../../test/deprovision_test"
            require 'test/unit/ui/console/testrunner'
            $manifest = Yajl::Parser.parse(resolve_manifest).merge("user_id" => id)
            Test::Unit.run = true
            Test::Unit::UI::Console::TestRunner.new(DeprovisionTest.suite).start
          when "planchange"
            id   = @args.shift || abort("! no id specified; see usage")
            plan = @args.shift || abort("! no plan specified; see usage")
            require "#{File.dirname(__FILE__)}/../../../test/plan_change_test"
            require 'test/unit/ui/console/testrunner'
            $manifest = Yajl::Parser.parse(resolve_manifest).merge("user_id" => id)
            Test::Unit.run = true
            Test::Unit::UI::Console::TestRunner.new(PlanChangeTest.suite).start
          when "sso"
            id = @args.shift || abort("! no id specified; see usage")
            require "#{File.dirname(__FILE__)}/../../../test/sso_test"
            require 'test/unit/ui/console/testrunner'
            $manifest = Yajl::Parser.parse(resolve_manifest).merge("user_id" => id)
            Test::Unit.run = true
            Test::Unit::UI::Console::TestRunner.new(SsoTest.suite).start
          else
            abort "! Unknown test '#{check}'; see usage"
        end
      end

      def run
        abort "! missing command to run; see usage" if @args.empty?
        run_check ManifestCheck
        run_check AllCheck, :args => @args
      end

      def sso
        id = @args.shift || abort("! no id specified; see usage")
        data = Yajl::Parser.parse(resolve_manifest).merge(:id => id)
        sso = Sso.new(data.merge(@options)).start
        puts sso.message
        Launchy.open sso.sso_url
      end

      def push
        user, password = ask_for_credentials
        host     = heroku_host
        data     = Yajl::Parser.parse(resolve_manifest)
        resource = RestClient::Resource.new(host, user, password)
        resource['provider/addons'].post(resolve_manifest, headers)
        puts "-----> Manifest for \"#{data['id']}\" was pushed successfully"
        puts "       Continue at #{(heroku_host)}/provider/addons/#{data['id']}"
      rescue RestClient::UnprocessableEntity => e
        abort("FAILED: #{e.http_body}")
      rescue RestClient::Unauthorized
        abort("Authentication failure")
      rescue RestClient::Forbidden
        abort("Not authorized to push this manifest. Please make sure you have permissions to push it")
      end

      def pull
        addon = @args.first || abort('usage: kensa pull <add-on name>')

        if manifest_exists?
          print "Manifest already exists. Replace it? (y/n) "
          abort unless gets.strip.downcase == 'y'
          puts
        end

        user, password = ask_for_credentials
        host     = heroku_host
        resource = RestClient::Resource.new(host, user, password)
        manifest = resource["provider/addons/#{addon}"].get(headers)
        File.open(filename, 'w') { |f| f.puts manifest }
        puts "-----> Manifest for \"#{addon}\" received successfully"
      end

      def version
        puts "Kensa #{Kensa::VERSION}"
      end

      private
        def headers
          { :accept => :json, "X-Kensa-Version" => "1", "User-Agent" => "kensa/#{Kensa::VERSION}" }
        end

        def heroku_host
          ENV['ADDONS_URL'] || 'https://addons.heroku.com'
        end

        def resolve_manifest
          if manifest_exists?
            File.read(filename)
          else
            abort("fatal: #{filename} not found")
          end
        end

        def manifest_exists?
          File.exists?(filename)
        end

        def run_check(*args)
          options = {}
          options = args.pop if args.last.is_a?(Hash)

          args.each do |klass|
            screen = Screen.new
            data   = Yajl::Parser.parse(resolve_manifest)
            check  = klass.new(data.merge(@options.merge(options)), screen)
            result = check.call
            screen.finish
            exit 1 if !result
          end
        end

        def running_on_windows?
          RUBY_PLATFORM =~ /mswin32|mingw32/
        end

        def echo_off
          system "stty -echo"
        end

        def echo_on
          system "stty echo"
        end

        def ask_for_credentials
          puts "Enter your Heroku Provider credentials."

          print "Email: "
          user = gets.strip

          print "Password: "
          password = running_on_windows? ? ask_for_password_on_windows : ask_for_password

          [ user, password ]
        end

        def ask_for_password_on_windows
          require "Win32API"
          char = nil
          password = ''

          while char = Win32API.new("crtdll", "_getch", [ ], "L").Call do
            break if char == 10 || char == 13 # received carriage return or newline
            if char == 127 || char == 8 # backspace and delete
              password.slice!(-1, 1)
            else
              password << char.chr
            end
          end
          puts
          return password
        end

        def ask_for_password
          echo_off
          password = gets.strip
          puts
          echo_on
          return password
        end


      class Screen
        include Term::ANSIColor

        def test(msg)
          $stdout.puts
          $stdout.puts
          $stdout.print "Testing #{msg}"
        end

        def check(msg)
          $stdout.puts
          $stdout.print "  Check #{msg}"
        end

        def error(msg)
          $stdout.print "\n", magenta("    ! #{msg}")
        end

        def result(status)
          msg = status ? bold("[PASS]") : red(bold("[FAIL]"))
          $stdout.print " #{msg}"
        end

        def message(msg)
          $stdout.print msg
        end

        def finish
          $stdout.puts
          $stdout.puts
          $stdout.puts "done."
        end
      end
    end
  end
end
