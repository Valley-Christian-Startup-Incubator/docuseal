# frozen_string_literal: true

class SubmissionEventsController < ApplicationController
  SUBMISSION_EVENT_ICONS = {
    'view_form' => 'eye',
    'start_form' => 'player_play',
    'complete_form' => 'check',
    'send_email' => 'mail_forward',
    'click_email' => 'hand_click',
    'api_complete_form' => 'check',
    'send_reminder_email' => 'mail_forward',
    'send_2fa_sms' => '2fa',
    'send_2fa_email' => '2fa',
    'send_sms' => 'send',
    'phone_verified' => 'phone_check',
    'email_verified' => 'email_check',
    'click_sms' => 'hand_click',
    'decline_form' => 'x',
    'delegate_form' => 'user_share',
    'start_verification' => 'player_play',
    'complete_verification' => 'check',
    'invite_party' => 'user_plus'
  }.freeze

  load_and_authorize_resource :submission

  def index
    respond_to do |format|
      format.html { render :index, layout: 'plain' }
      format.csv do
        authorize! :manage, :event_log_download
        response.headers['Cache-Control'] = 'no-store, private'
        csv = CSVSafe.generate do |rows|
          rows << ['Event time (UTC)', 'Event', 'Signer name', 'Signer email', 'IP address', 'User agent']
          @submission.submission_events.includes(:submitter).order(:event_timestamp, :id).each do |event|
            rows << [event.event_timestamp.utc.iso8601(3), event.event_type, event.submitter&.name,
                     event.data['email'].presence || event.submitter&.email, event.data['ip'], event.data['ua']]
          end
        end
        send_data csv, filename: "submission-#{@submission.id}-events.csv", type: 'text/csv'
      end
    end
  end
end
