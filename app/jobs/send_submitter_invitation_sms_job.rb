# frozen_string_literal: true

class SendSubmitterInvitationSmsJob
  include Sidekiq::Job
  sidekiq_options retry: 3

  def perform(params)
    submitter = Submitter.find(params.fetch('submitter_id'))
    submission = submitter.submission
    return if submitter.account.archived_at?
    return if submitter.completed_at? || submitter.declined_at? || submission.completed_at? || submission.archived_at? || submission.expired? || submission.template&.archived_at?
    return unless Submitters::AuthorizedForForm.pass_submitters_order?(submitter)
    return if submitter.phone.blank?
    url = Rails.application.routes.url_helpers.submit_form_url(submitter.slug, **Docuseal.default_url_options)
    Vcs::Sms.send!(submitter.account, submitter.phone, "Valley Christian Schools: Please review and sign your document: #{url}")
    SubmissionEvent.create!(submitter:, event_type: 'send_sms')
    submitter.update!(sent_at: submitter.sent_at || Time.current)
  end
end
