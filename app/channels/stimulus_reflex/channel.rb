# frozen_string_literal: true

class StimulusReflex::Channel < StimulusReflex.configuration.parent_channel.constantize
  attr_reader :reflex_data

  def stream_name
    [params[:channel], connection.connection_identifier].join(":")
  end

  def subscribed
    super
    stream_from stream_name
  end

  def receive(data)
    @reflex_data = StimulusReflex::ReflexData.new(data)
    begin
      begin
        reflex = StimulusReflex::ReflexFactory.create_reflex_from_data(self, @reflex_data)
        delegate_call_to_reflex reflex
      rescue => exception
        error = exception_with_backtrace(exception)
        error_message = "\e[31mReflex #{reflex_data.target} failed: #{error[:message]} [#{reflex_data.url}]\e[0m\n#{error[:stack]}"

        if reflex
          reflex.rescue_with_handler(exception)
          reflex.logger&.error error_message
          reflex.error data: data, body: "#{exception} #{exception.backtrace.first.split(":in ")[0] if Rails.env.development?}"
        else
          if exception.is_a? StimulusReflex::Reflex::VersionMismatchError
            mismatch = "Reflex failed due to stimulus_reflex gem/NPM package version mismatch. Package versions must match exactly.\nNote that if you are using pre-release builds, gems use the \"x.y.z.preN\" version format, while NPM packages use \"x.y.z-preN\".\n\nstimulus_reflex gem: #{StimulusReflex::VERSION}\nstimulus_reflex NPM: #{data["version"]}"

            StimulusReflex.config.logger.error("\n\e[31m#{mismatch}\e[0m") unless StimulusReflex.config.on_failed_sanity_checks == :ignore

            if Rails.env.development?
              CableReady::Channels.instance[stream_name].console_log(
                message: mismatch,
                level: "error",
                reflex_id: data["reflexId"]
              ).broadcast
            end

            if StimulusReflex.config.on_failed_sanity_checks == :exit
              sleep 0.1
              exit!
            end
          else
            StimulusReflex.config.logger.error error_message
          end

          if body.to_s.include? "No route matches"
            initializer_path = Rails.root.join("config", "initializers", "stimulus_reflex.rb")

            StimulusReflex.config.logger.warn <<~NOTE
              \e[33mNOTE: StimulusReflex failed to locate a matching route and could not re-render the page.

              If your app uses Rack middleware to rewrite part of the request path, you must enable those middleware modules in StimulusReflex.
              The StimulusReflex initializer should be located at #{initializer_path}, or you can generate it with:

                $ bundle exec rails generate stimulus_reflex:config

              Configure any required middleware:

                StimulusReflex.configure do |config|
                  config.middleware.use FirstRackMiddleware
                  config.middleware.use SecondRackMiddleware
                end\e[0m

            NOTE
          end
        end
        return
      end

      if reflex.halted?
        reflex.halted data: data
      else
        begin
          reflex.broadcast(reflex_data.selectors, data)
        rescue => exception
          reflex.rescue_with_handler(exception)
          error = exception_with_backtrace(exception)
          reflex.error data: data, body: "#{exception} #{exception.backtrace.first.split(":in ")[0] if Rails.env.development?}"
          reflex.logger&.error "\e[31mReflex failed to re-render: #{error[:message]} [#{reflex_data.url}]\e[0m\n#{error[:stack]}"
        end
      end
    ensure
      if reflex
        commit_session(reflex)
        report_failed_basic_auth(reflex) if reflex.controller?
        reflex.logger&.log_all_operations
      end
    end
  end

  private

  def delegate_call_to_reflex(reflex)
    method_name = reflex_data.method_name
    arguments = reflex_data.arguments
    method = reflex.method(method_name)

    policy = StimulusReflex::ReflexMethodInvocationPolicy.new(method, arguments)

    if policy.no_arguments?
      reflex.process(method_name)
    elsif policy.arguments?
      reflex.process(method_name, *arguments)
    else
      raise ArgumentError.new("wrong number of arguments (given #{arguments.inspect}, expected #{policy.required_params.inspect}, optional #{policy.optional_params.inspect})")
    end
  end

  def commit_session(reflex)
    store = reflex.request.session.instance_variable_get("@by")
    store.commit_session reflex.request, reflex.controller.response
  rescue => exception
    error = exception_with_backtrace(exception)
    reflex.logger&.error "\e[31mFailed to commit session! #{error[:message]}\e[0m\n#{error[:backtrace]}"
  end

  def report_failed_basic_auth(reflex)
    if reflex.controller.response.status == 401
      reflex.logger&.error "\e[31mReflex failed to process controller action \"#{reflex.controller.class}##{reflex.controller.action_name}\" due to HTTP basic auth. Consider adding \"unless: -> { @stimulus_reflex }\" to the before_action or method responible for authentication.\e[0m"
    end
  end

  def exception_with_backtrace(exception)
    {
      message: exception.to_s,
      backtrace: exception.backtrace.first.split(":in ")[0],
      stack: exception.backtrace.join("\n")
    }
  end
end
