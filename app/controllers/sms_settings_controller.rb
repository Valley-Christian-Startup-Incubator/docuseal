# frozen_string_literal: true

class SmsSettingsController < ApplicationController
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index
  authorize_resource :encrypted_config, parent: false, except: :index

  def index; end

  def create
    attrs = params.require(:sms).permit(:account_sid, :auth_token, :from).to_h
    attrs.delete('auth_token') if attrs['auth_token'].blank?
    value = (@encrypted_config.value || {}).merge(attrs)
    unless value['account_sid'].to_s.match?(/\AAC[a-f0-9]{32}\z/i) && value['from'].to_s.match?(/\A\+[1-9]\d{7,14}\z/) && value['auth_token'].present?
      return redirect_to settings_sms_path, alert: 'Provide a valid Twilio SID, auth token, and E.164 sender.'
    end
    @encrypted_config.update!(value:)
    redirect_to settings_sms_path, notice: 'SMS settings saved.'
  end

  private

  def load_encrypted_config
    @encrypted_config =
      EncryptedConfig.find_or_initialize_by(account: current_account, key: 'sms_configs')
  end
end
