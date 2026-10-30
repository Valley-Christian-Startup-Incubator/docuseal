# frozen_string_literal: true
class SubmitFormPhoneVerificationsController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check
  before_action :load_active_submitter

  def create
    RateLimit.call("verify-phone-#{@submitter.id}", limit: 5, ttl: 1.minute, enabled: true)
    if OtpChallenges.verify(params[:one_time_code].to_s, challenge_key, purpose: 'form_phone_2fa')
      cookies.encrypted[:phone_2fa_slug] = { value: @submitter.slug, expires: 1.hour.from_now, httponly: true, secure: request.ssl?, same_site: :lax }
      SubmissionEvents.create_with_tracking_data(@submitter, 'phone_verified', request, {})
      redirect_to submit_form_path(@submitter.slug)
    else
      redirect_to submit_form_path(@submitter.slug), alert: 'Invalid or expired code.'
    end
  end

  def update
    RateLimit.call("send-phone-code-#{@submitter.id}", limit: 1, ttl: 1.minute, enabled: true)
    code = OtpChallenges.generate(challenge_key, purpose: 'form_phone_2fa')
    Vcs::Sms.send!(@submitter.account, @submitter.phone, "Your Valley Christian Sign verification code is #{code}. It expires in 10 minutes.")
    redirect_to submit_form_path(@submitter.slug), notice: 'Verification code sent.'
  rescue Vcs::Sms::Error => e
    redirect_to submit_form_path(@submitter.slug), alert: e.message
  end

  private

  def load_active_submitter
    @submitter = Submitter.find_by!(slug: params[:submitter_slug])
    submission = @submitter.submission
    required = @submitter.preferences['require_phone_2fa'] == true || submission.template&.preferences&.dig('require_phone_2fa') == true
    return if required && !@submitter.completed_at? && !@submitter.declined_at? &&
              !submission.completed_at? && !submission.archived_at? && !submission.expired? &&
              !submission.template&.archived_at? && !@submitter.account.archived_at?

    head :not_found
  end

  def challenge_key = "#{@submitter.phone}:#{@submitter.slug}"
end
