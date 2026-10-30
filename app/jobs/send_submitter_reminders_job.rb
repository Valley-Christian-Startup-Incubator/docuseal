# frozen_string_literal: true

class SendSubmitterRemindersJob
  include Sidekiq::Job
  sidekiq_options retry: 3

  def perform
    Submitter.where(completed_at: nil, declined_at: nil).where.not(sent_at: nil).where.not(email: [nil, '']).find_each do |submitter|
      submission = submitter.submission
      next if submission.completed_at? || submission.archived_at? || submission.expired? || submission.template&.archived_at?
      next if submitter.preferences['send_email'] == false || !Submitters::AuthorizedForForm.pass_submitters_order?(submitter)
      next unless Accounts.can_send_emails?(submitter.account, on_events: true)
      config = AccountConfigs.find_for_account(submitter.account, AccountConfig::SUBMITTER_REMINDERS)&.value
      next unless config.is_a?(Hash)

      %w[first_duration second_duration third_duration].each do |key|
        duration = AccountConfigs::REMINDER_DURATIONS[config[key]]
        next unless duration
        count, unit = duration.split(' ')
        due_at = submitter.sent_at + count.to_i.public_send(unit)
        next if due_at > Time.current
        submitter.with_lock do
          sent = Array(submitter.preferences['vcs_reminders_sent'])
          marker = "#{submitter.sent_at.to_i}:#{key}"
          next if sent.include?(marker)
          SendSubmitterInvitationEmailJob.perform_async('submitter_id' => submitter.id, 'reminder' => true, 'delivery_key' => "reminder:#{submitter.id}:#{marker}")
          submitter.update!(preferences: submitter.preferences.merge('vcs_reminders_sent' => [*sent, marker]))
        end
      end
    end
    ActiveStorage::Blob.find_each do |blob|
      next unless blob.metadata['vcs_import_user']
      if blob.metadata['vcs_import_consumed'] && !blob.metadata['vcs_import_dispatched']
        Vcs::ImportDelivery.dispatch(blob)
      elsif blob.created_at < 2.hours.ago && !blob.attachments.exists?
        blob.purge_later
      end
    end
  end
end
