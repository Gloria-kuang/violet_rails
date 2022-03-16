class ExternalApiClient < ApplicationRecord
  STATUSES = {
    stopped: 'stopped',
    running: 'running',
    error: 'error',
    sleeping: 'sleeping'
  }

  DRIVE_STRATEGIES = {
    on_demand: 'on_demand',
    cron: 'cron'
  }

  CLIENT_INTERFACE_MAPPING = {
    modmed: 'External::ApiClients::Modmed'
  }

  extend FriendlyId
  friendly_id :label, use: :slugged
  belongs_to :api_namespace

  validates :status, inclusion: { in: ExternalApiClient::STATUSES.keys.map(&:to_s)  }
  validates :drive_strategy, inclusion: { in: ExternalApiClient::DRIVE_STRATEGIES.keys.map(&:to_s) }

  def run
    return false if !self.enabled || self.status == ExternalApiClient::STATUSES[:error]
    external_api_interface = ExternalApiClient::CLIENT_INTERFACE_MAPPING[self.slug.to_sym].constantize
    external_api_interface_supervisor = external_api_interface.new(external_api_client: self)
    retries = nil
    begin
      self.reload
      retries = self.retries
      self.update(status: ExternalApiClient::STATUSES[:running])
      external_api_interface_supervisor.start(self)
    rescue StandardError => e
      self.update(error_message: e.message) 
      if retries <= self.max_retries
        self.update(retries: retries + 1)
        max_sleep_seconds = Float(2 ** retries)
        sleep_for_seconds = rand(0..max_sleep_seconds)
        self.update(retry_in_seconds: max_sleep_seconds)
        self.update(status: ExternalApiClient::STATUSES[:sleeping])
        sleep sleep_for_seconds
        retry
      else
        # client is considered dead at this point, fire off a flare
        self.update(
          error_message: e.message,
          status: ExternalApiClient::STATUSES[:error]
        )
        external_api_interface_supervisor.log
      end
    end
  end

  def get_metadata
    JSON.parse(self.metadata).deep_symbolize_keys
  end
end
