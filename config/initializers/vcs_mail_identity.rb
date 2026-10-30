# frozen_string_literal: true

class VcsMailJobIdentity
  def call(_worker, job, _queue)
    previous = Thread.current[:vcs_mail_job_id]
    Thread.current[:vcs_mail_job_id] = job['jid']
    yield
  ensure
    Thread.current[:vcs_mail_job_id] = previous
  end
end

Sidekiq.configure_server { |config| config.server_middleware { |chain| chain.add VcsMailJobIdentity } }
ActiveSupport.on_load(:sidekiq_config) { |config| config.server_middleware { |chain| chain.add VcsMailJobIdentity } }
