require 'securerandom'
require 'cloud_controller/diego/staging_completion_handler_base'

module VCAP::CloudController
  module Diego
    module Docker
      class StagingCompletionHandler < VCAP::CloudController::Diego::StagingCompletionHandlerBase
        def initialize(runners=CloudController::DependencyLocator.instance.runners)
          super(runners, Steno.logger('cc.docker.stager'), 'diego.docker.staging.')
        end

        def self.success_parser
          @staging_response_schema ||= Membrane::SchemaParser.parse do
            {
              result: {
                execution_metadata: String,
                process_types:      dict(Symbol, String),
                lifecycle_type:     Lifecycles::DOCKER,
                lifecycle_metadata: {
                  docker_image: String
                }
              }
            }
          end
        end

        private

        def save_staging_result(process, payload)
          result = payload[:result]

          process.class.db.transaction do
            process.lock!

            process.mark_as_staged
            process.add_new_droplet(SecureRandom.hex) # placeholder until image ID is obtained during staging

            if result.key?(:execution_metadata)
              droplet = process.current_droplet
              droplet.lock!
              droplet.update_execution_metadata(result[:execution_metadata])
              droplet.update_detected_start_command(result[:process_types][:web])
            end

            cached_image = result[:lifecycle_metadata][:docker_image]
            if cached_image.present?
              droplet.update_cached_docker_image(cached_image)
            else
              droplet.update_cached_docker_image(nil)
            end

            process.save_changes(raise_on_save_failure: true)
          end
        end

        def handle_success(staging_guid, payload)
          begin
            process = get_process(staging_guid)
            return if process.nil?

            self.class.success_parser.validate(payload)

          rescue Membrane::SchemaValidationError => e
            logger.error('diego.staging.success.invalid-message', staging_guid: staging_guid, payload: payload, error: e.to_s)
            Loggregator.emit_error(process.guid, 'Malformed message from Diego stager')

            process.mark_as_failed_to_stage('StagingError')
            raise CloudController::Errors::ApiError.new_from_details('InvalidRequest', payload)
          end

          begin
            save_staging_result(process, payload)
            @runners.runner_for_app(process).start
          rescue => e
            logger.error(@logger_prefix + 'saving-staging-result-failed', staging_guid: staging_guid, response: payload, error: e.message)
          end
        end
      end
    end
  end
end
