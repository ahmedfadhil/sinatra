require 'uri'
require 'rack'
require 'rack/builder'
require 'sinatra/rack/methodoverride'

module Sinatra
  VERSION = '0.9.0'

  class Request < Rack::Request
    def user_agent
      @env['HTTP_USER_AGENT']
    end
  end

  class Response < Rack::Response
  end

  class NotFound < NameError # :)
    def code ; 404 ; end
  end

  module Helpers
    # Set or retrieve the response status code.
    def status(value=nil)
      response.status = value if value
      response.status
    end

    # Set or retrieve the response body. When a block is given,
    # evaluation is deferred until the body is read with #each.
    def body(value=nil, &block)
      if block_given?
        def block.each ; yield call ; end
        response.body = block
      else
        response.body = value
      end
      response.body
    end

    # Halt processing and redirect to the URI provided.
    def redirect(uri, *args)
      status 302
      response['Location'] = uri
      halt *args
    end

    # Halt processing and return the error status provided.
    def error(code, body=nil)
      code, body = 500, code.to_str if code.respond_to? :to_str
      response.body = body unless body.nil?
      halt code
    end

    # Halt processing and return a 404 Not Found.
    def not_found(body=nil)
      error 404, body
    end

    # Access the underlying Rack session.
    def session
      env['rack.session'] ||= {}
    end

    # Set the content type of the response body (HTTP 'Content-Type' header).
    #
    # The +type+ argument may be a media type (e.g., 'text/html',
    # 'application/xml+atom', 'image/png') or a Symbol key into the
    # Rack::File::MIME_TYPES table.
    #
    # Media type parameters, such as "charset", may also be specified using the
    # optional hash argument:
    #   get '/foo.html' do
    #     content_type 'text/html', :charset => 'utf-8'
    #     "<h1>Hello World</h1>"
    #   end
    def content_type(type, params={})
      mediatype =
        if type.kind_of?(Symbol)
          Rack::File::MIME_TYPES[type.to_s]
        else
          type
        end
      fail "Invalid or undefined media type: #{type.inspect}" if mediatype.nil?
      if params.any?
        params = params.collect { |kv| "%s=%s" % kv }.join(', ')
        response['Content-Type'] = [mediatype, params].join(";")
      else
        response['Content-Type'] = mediatype
      end
    end

    def send_file(path)
      stat = File.stat(path)
      last_modified stat.mtime
      response['Content-Length'] ||= stat.size.to_s
      response['Content-Type'] =
        Rack::File::MIME_TYPES[File.extname(path)[1..-1]] ||
        response['Content-Type'] ||
        'application/octet-stream'
      throw :halt, StaticFile.open(path, 'rb')
    rescue Errno::ENOENT
      not_found
    end

    class StaticFile < ::File #:nodoc:
      alias_method :to_path, :path
      def each
        while buf = read(8196)
          yield buf
        end
      end
    end

    # Set the last modified time of the resource (HTTP 'Last-Modified' header)
    # and halt if conditional GET matches. The +time+ argument is a Time,
    # DateTime, or other object that responds to +to_time+.
    #
    # When the current request includes an 'If-Modified-Since' header that
    # matches the time specified, execution is immediately halted with a
    # '304 Not Modified' response.
    def last_modified(time)
      time = time.to_time if time.respond_to?(:to_time)
      time = time.httpdate if time.respond_to?(:httpdate)
      response['Last-Modified'] = time
      halt 304 if time == request.env['HTTP_IF_MODIFIED_SINCE']
      time
    end

    # Set the response entity tag (HTTP 'ETag' header) and halt if conditional
    # GET matches. The +value+ argument is an identifier that uniquely
    # identifies the current version of the resource. The +strength+ argument
    # indicates whether the etag should be used as a :strong (default) or :weak
    # cache validator.
    #
    # When the current request includes an 'If-None-Match' header with a
    # matching etag, execution is immediately halted. If the request method is
    # GET or HEAD, a '304 Not Modified' response is sent.
    def etag(value, strength=:strong)
      value =
        case strength
        when :strong then '"%s"' % value
        when :weak   then 'W/"%s"' % value
        else         raise TypeError, "strength must be one of :strong or :weak"
        end
      response['ETag'] = value

      # Check for If-None-Match request header and halt if match is found.
      etags = (request.env['HTTP_IF_NONE_MATCH'] || '').split(/\s*,\s*/)
      if etags.include?(value) || etags.include?('*')
        # GET/HEAD requests: send Not Modified response
        halt 304 if request.get? || request.head?
        # Other requests: send Precondition Failed response
        halt 412
      end
    end
  end

  module Templates
    def render(engine, template, options={})
      data = lookup_template(engine, template, options)
      output = __send__("render_#{engine}", template, data, options)
      layout, data = lookup_layout(engine, options)
      if layout
        __send__("render_#{engine}", layout, data, options) { output }
      else
        output
      end
    end

    def lookup_template(engine, template, options={})
      case template
      when Symbol
        if cached = self.class.templates[template]
          lookup_template(engine, cached, options)
        else
          ::File.read(template_path(engine, template, options))
        end
      when Proc
        template.call
      when String
        template
      else
        raise ArgumentError
      end
    end

    def lookup_layout(engine, options)
      return if options[:layout] == false
      template = options[:layout] || :layout
      data = lookup_template(engine, template, options)
      [template, data]
    rescue Errno::ENOENT
      nil
    end

    def template_path(engine, template, options={})
      views_dir =
        options[:views_directory] || self.options.views || "./views"
      "#{views_dir}/#{template}.#{engine}"
    end

    def erb(template, options={})
      require 'erb' unless defined? ::ERB
      render :erb, template, options
    end

    def render_erb(template, data, options, &block)
      data = data.call if data.kind_of? Proc
      instance = ::ERB.new(data)
      locals = options[:locals] || {}
      locals_assigns = locals.to_a.collect { |k,v| "#{k} = locals[:#{k}]" }
      src = "#{locals_assigns.join("\n")}\n#{instance.src}"
      eval src, binding, '(__ERB__)', locals_assigns.length + 1
      instance.result(binding)
    end

    def haml(template, options={})
      require 'haml' unless defined? ::Haml
      options[:options] ||= self.class.haml if self.class.respond_to? :haml
      render :haml, template, options
    end

    def render_haml(template, data, options, &block)
      engine = ::Haml::Engine.new(data, options[:options] || {})
      engine.render(self, options[:locals] || {}, &block)
    end

    def sass(template, options={}, &block)
      require 'sass' unless defined? ::Sass
      options[:layout] = false
      render :sass, template, options
    end

    def render_sass(template, data, options, &block)
      engine = ::Sass::Engine.new(data, options[:sass] || {})
      engine.render
    end

    def builder(template=nil, options={}, &block)
      require 'builder' unless defined? ::Builder
      options, template = template, nil if template.is_a?(Hash)
      template = lambda { block } if template.nil?
      render :builder, template, options
    end

    def render_builder(template, data, options, &block)
      xml = ::Builder::XmlMarkup.new(:indent => 2)
      if data.respond_to?(:to_str)
        eval data.to_str, binding, '<BUILDER>', 1
      elsif data.kind_of?(Proc)
        data.call(xml)
      end
      xml.target!
    end

  end

  class Base
    include Rack::Utils
    include Helpers
    include Templates

    attr_accessor :app

    def initialize(app=nil)
      @app = app
      yield self if block_given?
    end

    def call(env)
      dup.call!(env)
    end

    attr_accessor :env, :request, :response, :params

    def call!(env)
      @env = env
      @request = Request.new(env)
      @response = Response.new
      @params = nil
      error_detection { dispatch! }
      @response.finish
    end

    def options
      self.class
    end

    def halt(*response)
      throw :halt, *response
    end

    def pass
      throw :pass
    end

  private
    def dispatch!
      self.class.filters.each {|block| instance_eval(&block)}
      if routes = self.class.routes[@request.request_method]
        path = @request.path_info
        original_params = Hash.new{ |hash,k| hash[k.to_s] if Symbol === k }
        original_params.merge! @request.params

        routes.each do |pattern, keys, conditions, block|
          if pattern =~ path
            values = $~.captures.map{|val| val && unescape(val) }
            params =
              if keys.any?
                keys.zip(values).inject({}) do |hash,(k,v)|
                  if k == 'splat'
                    (hash[k] ||= []) << v
                  else
                    hash[k] = v
                  end
                  hash
                end
              elsif values.any?
                {'captures' => values}
              else
                {}
              end
            @params = original_params.dup
            @params.merge!(params)

            catch(:pass) {
              conditions.each { |cond|
                throw :pass if instance_eval(&cond) == false }
              return invoke(block)
            }
          end
        end
      end
      raise NotFound
    end

    def invoke(block)
      res = catch(:halt) { instance_eval(&block) }
      case
      when res.respond_to?(:to_str)
        @response.body = [res]
      when res.respond_to?(:to_ary)
        res = res.to_ary
        if Fixnum === res.first
          if res.length == 3
            @response.status, headers, body = res
            @response.body = body if body
            headers.each { |k, v| @response.headers[k] = v } if headers
          elsif res.length == 2
            @response.status = res.first
            @response.body = res.last
          else
            raise TypeError, "#{res.inspect} not supported"
          end
        else
          @response.body = res
        end
      when res.kind_of?(Symbol)  # TODO: deprecate this.
        @response.body = __send__(res)
      when res.respond_to?(:each)
        @response.body = res
      when (100...599) === res
        @response.status = res
      when res.nil?
        @response.body = []
      else
        raise TypeError, "#{res.inspect} not supported"
      end
      res
    end

    def error_detection
      errmap = self.class.errors
      yield
    rescue NotFound => boom
      @env['sinatra.error'] = boom
      @response.status = 404
      @response.body = ['<h1>Not Found</h1>']
      invoke errmap[NotFound] if errmap.key?(NotFound)
    rescue ::Exception => boom
      @env['sinatra.error'] = boom
      raise boom if options.raise_errors?
      @response.status = 500
      invoke errmap[boom.class] || errmap[Exception]
    ensure
      if @response.status >= 400 && errmap.key?(response.status)
        invoke errmap[response.status]
      end
    end

    @routes = {}
    @filters = []
    @conditions = []
    @templates = {}
    @middleware = []
    @callsite = nil
    @errors = {}

    class << self
      attr_accessor :routes, :filters, :conditions, :templates,
        :middleware, :errors

      def set(option, value=self)
        if value.kind_of?(Proc)
          metadef(option, &value)
          metadef("#{option}?") { !!__send__(option) }
          metadef("#{option}=") { |val| set(option, Proc.new{val}) }
        elsif value == self && option.respond_to?(:to_hash)
          option.to_hash.each(&method(:set))
        elsif respond_to?("#{option}=")
          __send__ "#{option}=", value
        else
          set option, Proc.new{value}
        end
        self
      end

      def enable(*opts)
        opts.each { |key| set(key, true) }
      end

      def disable(*opts)
        opts.each { |key| set(key, false) }
      end

      def error(codes=Exception, &block)
        if codes.respond_to? :each
          codes.each { |err| error(err, &block) }
        else
          @errors[codes] = block
        end
      end

      def template(name, &block)
        templates[name] = block
      end

      def layout(name=:layout, &block)
        template name, &block
      end

      def use_in_file_templates!
        line = caller.detect { |s| s !~ /lib\/sinatra.*\.rb/ &&
          s !~ /\(.*\)/ }
        file = line.sub(/:\d+.*$/, '')
        if data = ::IO.read(file).split('__END__')[1]
          data.gsub! /\r\n/, "\n"
          template = nil
          data.each_line do |line|
            if line =~ /^@@\s*(.*)/
              template = templates[$1.to_sym] = ''
            elsif template
              template << line
            end
          end
        end
      end

      def before(&block)
        @filters << block
      end

      def condition(&block)
        @conditions << block
      end

      def host_name(pattern)
        condition { pattern === request.host }
      end

      def user_agent(pattern)
        condition {
          if request.user_agent =~ pattern
            @params[:agent] = $~[1..-1]
            true
          else
            false
          end
        }
      end

      def get(path, opts={}, &block)
        conditions = @conditions.dup
        route 'GET', path, opts, &block

        @conditions = conditions
        head(path, opts) { invoke(block) ; [] }
      end

      def put(path, opts={}, &bk); route 'PUT', path, opts, &bk; end
      def post(path, opts={}, &bk); route 'POST', path, opts, &bk; end
      def delete(path, opts={}, &bk); route 'DELETE', path, opts, &bk; end
      def head(path, opts={}, &bk); route 'HEAD', path, opts, &bk; end

    private
      def route(method, path, opts={}, &block)
        host_name  opts[:host]  if opts.key?(:host)
        user_agent opts[:agent] if opts.key?(:agent)

        pattern, keys = compile(path)
        conditions, @conditions = @conditions, []
        (routes[method] ||= []).
          push [pattern, keys, conditions, block]
      end

      def compile(path)
        keys = []
        if path.respond_to? :to_str
          pattern =
            URI.encode(path).gsub(/((:\w+)|\*)/) do |match|
              if match == "*"
                keys << 'splat'
                "(.*?)"
              else
                keys << $2[1..-1]
                "([^/?&#\.]+)"
              end
            end
          [/^#{pattern}$/, keys]
        elsif path.respond_to? :=~
          [path, keys]
        else
          raise TypeError, path
        end
      end

    public
      def development? ; environment == :development ; end
      def test? ; environment == :test ; end
      def production? ; environment == :production ; end

      def configure(*envs, &block)
        yield if envs.empty? || envs.include?(environment.to_sym)
      end

      def use(middleware, *args, &block)
        reset_middleware
        @middleware << [middleware, args, block]
      end

      def run!(options={})
        set(options)
        handler = Rack::Handler.get(server)
        handler_name = handler.name.gsub(/.*::/, '')
        puts "== Sinatra/#{Sinatra::VERSION} has taken the stage " +
          "on #{port} for #{environment} with backup from #{handler_name}"
        handler.run self, :Host => host, :Port => port do |server|
          trap(:INT) do
            server.stop
            puts "\n== Sinatra has ended his set (crowd applauds)"
          end
        end
      rescue Errno::EADDRINUSE => e
        puts "== Someone is already performing on port #{port}!"
      end

      def call(env)
        construct_middleware if @callsite.nil?
        @callsite.call(env)
      end

    private
      def construct_middleware(builder=Rack::Builder.new)
        builder.use Rack::Session::Cookie if sessions?
        builder.use Rack::CommonLogger if logging?
        builder.use Rack::MethodOverride if methodoverride?
        @middleware.each { |c, args, bk| builder.use(c, *args, &bk) }
        builder.run new
        @callsite = builder.to_app
      end

      def reset_middleware
        @callsite = nil
      end

      def inherited(subclass)
        subclass.routes = dupe_routes
        subclass.templates = templates.dup
        subclass.conditions = []
        subclass.filters = filters.dup
        subclass.errors = errors.dup
        subclass.middleware = middleware.dup
        subclass.send :reset_middleware
        super
      end

      def dupe_routes
        routes.inject({}) do |hash,(request_method,routes)|
          hash[request_method] = routes.dup
          hash
        end
      end

      def metadef(message, &block)
        (class << self; self; end).
          send :define_method, message, &block
      end
    end

    set :raise_errors, true
    set :sessions, false
    set :logging, false
    set :methodoverride, false
    set :static, false
    set :environment, (ENV['RACK_ENV'] || :development).to_sym

    set :run, false
    set :server, (defined?(Rack::Handler::Thin) ? "thin" : "mongrel")
    set :host, '0.0.0.0'
    set :port, 4567

    set :app_file, nil
    set :root, Proc.new { app_file && File.expand_path(File.dirname(app_file)) }
    set :views, Proc.new { root && File.join(root, 'views') }
    set :public, Proc.new { root && File.join(root, 'public') }

    # static files route
    get(/.*[^\/]$/) do
      pass unless options.static? && options.public?
      path = options.public + unescape(request.path_info)
      pass unless File.file?(path)
      send_file path
    end

    error ::Exception do
      response.status = 500
      content_type 'text/html'
      '<h1>Internal Server Error</h1>'
    end

    configure :development do
      get '/__sinatra__/:image.png' do
        filename = File.dirname(__FILE__) + "/images/#{params[:image]}.png"
        content_type :png
        send_file filename
      end

      error NotFound do
        (<<-HTML).gsub(/^ {8}/, '')
        <!DOCTYPE html>
        <html>
        <head>
          <style type="text/css">
          body { text-align:center;font-family:helvetica,arial;font-size:22px;
            color:#888;margin:20px}
          #c {margin:0 auto;width:500px;text-align:left}
          </style>
        </head>
        <body>
          <h2>Sinatra doesn't know this ditty.</h2>
          <img src='/__sinatra__/404.png'>
          <div id="c">
            Try this:
            <pre>#{request.request_method.downcase} '#{request.path_info}' do\n  "Hello World"\nend</pre>
          </div>
        </body>
        </html>
        HTML
      end

      error do
        next unless err = request.env['sinatra.error']
        heading = err.class.name + ' - ' + err.message.to_s
        (<<-HTML).gsub(/^ {8}/, '')
        <!DOCTYPE html>
        <html>
        <head>
          <style type="text/css">
            body {font-family:verdana;color:#333}
            #c {margin-left:20px}
            h1 {color:#1D6B8D;margin:0;margin-top:-30px}
            h2 {color:#1D6B8D;font-size:18px}
            pre {border-left:2px solid #ddd;padding-left:10px;color:#000}
            img {margin-top:10px}
          </style>
        </head>
        <body>
          <div id="c">
            <img src="/__sinatra__/500.png">
            <h1>#{escape_html(heading)}</h1>
            <pre class='trace'>#{escape_html(err.backtrace.join("\n"))}</pre>
            <h2>Params</h2>
            <pre>#{escape_html(params.inspect)}</pre>
          </div>
        </body>
        </html>
        HTML
      end
    end
  end

  class Default < Base
    set :raise_errors, false
    set :sessions, false
    set :logging, true
    set :methodoverride, true
    set :static, true
    set :run, false
    set :reload, Proc.new { app_file? && development? }

    @reloading = false

    class << self
      def reloading?
        @reloading
      end

      def configure(*envs)
        super unless reloading?
      end

      def call(env)
        reload! if reload?
        super
      end

      def reload!
        @reloading = true
        superclass.send :inherited, self
        ::Kernel.load app_file
        @reloading = false
      end
    end
  end

  class Application < Default
  end

  module Delegator
    METHODS = %w[
      get put post delete head template layout before error not_found
      configures configure set set_option set_options enable disable use
      development? test? production? use_in_file_templates!
    ]

    METHODS.each do |method_name|
      eval <<-RUBY, binding, '(__DELEGATE__)', 1
        def #{method_name}(*args, &b)
          ::Sinatra::Application.#{method_name}(*args, &b)
        end
        private :#{method_name}
      RUBY
    end
  end

  def self.new(base=Base, options={}, &block)
    base = Class.new(base)
    base.send :class_eval, &block if block_given?
    base
  end
end

# Make Rack 0.5.0 backward compatibile with 0.4.0 mime types
require 'rack/file'
class Rack::File
  unless defined? MIME_TYPES
    MIME_TYPES = Hash.new {|hash,key|
      Rack::Mime::MIME_TYPES[".#{key}"] }
  end
end
