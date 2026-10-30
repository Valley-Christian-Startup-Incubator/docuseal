# frozen_string_literal: true
class SubmittersSendSmsController < ApplicationController
  load_and_authorize_resource :submitter
  def create
    authorize!(:update, @submitter)
    raise Vcs::Sms::Error, 'Configure SMS credentials first.' unless Vcs::Sms.configured?(current_account)
    RateLimit.call("send-sms-#{@submitter.id}", limit: 1, ttl: 1.minute, enabled: true)
    SendSubmitterInvitationSmsJob.perform_async('submitter_id' => @submitter.id)
    redirect_back fallback_location: submission_path(@submitter.submission), notice: 'SMS invitation queued.'
  rescue Vcs::Sms::Error => e
    redirect_back fallback_location: root_path, alert: e.message
  end
end
