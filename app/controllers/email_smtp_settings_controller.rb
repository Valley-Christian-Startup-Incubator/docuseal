# frozen_string_literal: true

class EmailSmtpSettingsController < ApplicationController
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index
  authorize_resource :encrypted_config, parent: false, only: %i[create destroy]

  def index; end

  def create
    if @encrypted_config.update(resend_request? ? resend_configs : email_configs)
      unless Docuseal.multitenant?
        SettingsMailer.smtp_successful_setup(@encrypted_config.value['from_email'] || current_user.email).deliver_now!
      end

      redirect_to settings_email_index_path, notice: I18n.t('changes_have_been_saved')
    else
      render :index, status: :unprocessable_content
    end
  rescue StandardError => e
    flash[:alert] = e.message

    render :index, status: :unprocessable_content
  end

  def destroy
    @encrypted_config.destroy!

    redirect_to settings_email_index_path, notice: I18n.t('smtp_settings_have_been_reset')
  end

  private

  def load_encrypted_config
    @resend_config = EncryptedConfig.find_or_initialize_by(account: current_account, key: 'resend_api')
    @encrypted_config = if resend_request?
                          @resend_config
                        else
                          EncryptedConfig.find_or_initialize_by(account: current_account,
                                                                key: EncryptedConfig::EMAIL_SMTP_KEY)
                        end
  end

  def resend_request?
    params.key?(:resend_api)
  end

  def resend_configs
    value = params.require(:resend_api).permit(:api_key, :from_email).to_h
    value['api_key'] = @resend_config.value&.fetch('api_key', nil) if value['api_key'].blank?
    value['from_email'] = value['from_email'].to_s.strip

    unless value['api_key'].is_a?(String) && value['api_key'].present? && !value['api_key'].match?(/[\r\n]/)
      raise Vcs::ResendDelivery::DeliveryError, 'Resend API key is required'
    end
    unless value['from_email'].match?(User::FULL_EMAIL_REGEXP)
      raise Vcs::ResendDelivery::DeliveryError, 'A valid sender email is required'
    end

    { value: }
  end

  def email_configs
    params.require(:encrypted_config).permit(value: {}).tap do |e|
      e[:value].compact_blank!
    end
  end
end
