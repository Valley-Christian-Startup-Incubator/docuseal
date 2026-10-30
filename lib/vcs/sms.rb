# frozen_string_literal: true

require 'net/http'

module Vcs
  module Sms
    Error = Class.new(StandardError)
    module_function

    def config(account)
      account.encrypted_configs.find_by(key: 'sms_configs')&.value || {}
    end

    def configured?(account)
      values = config(account)
      %w[account_sid auth_token from].all? { |key| values[key].present? }
    end

    def send!(account, phone, body)
      settings = config(account)
      raise Error, 'Configure SMS credentials in Settings → SMS first.' unless configured?(account)
      raise Error, 'Use an E.164 phone number, such as +14085551234.' unless phone.to_s.match?(/\A\+[1-9]\d{7,14}\z/)
      sid = settings.fetch('account_sid')
      raise Error, 'Invalid Twilio account SID.' unless sid.match?(/\AAC[a-f0-9]{32}\z/i)
      uri = URI("https://api.twilio.com/2010-04-01/Accounts/#{sid}/Messages.json")
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(sid, settings.fetch('auth_token'))
      request.set_form_data('To' => phone, 'From' => settings.fetch('from'), 'Body' => body)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(request) }
      raise Error, "SMS provider rejected the message (HTTP #{response.code})." unless response.is_a?(Net::HTTPSuccess)
      true
    end
  end
end
