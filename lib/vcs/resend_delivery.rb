# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'net/http'
require 'securerandom'
require 'timeout'

module Vcs
  class ResendDelivery
    ENDPOINT = URI('https://api.resend.com/emails')
    ADDRESS_FIELDS = %i[to cc bcc reply_to].freeze
    HEADER_NAMES = %w[Message-ID In-Reply-To References X-Message-Uuid].freeze

    class DeliveryError < StandardError; end

    attr_accessor :settings

    def initialize(settings = {})
      @settings = settings.transform_keys(&:to_sym)
    end

    def deliver!(mail)
      validate_settings!
      payload = build_payload(mail)
      request = Net::HTTP::Post.new(ENDPOINT)
      request['Authorization'] = "Bearer #{settings.fetch(:api_key)}"
      request['Content-Type'] = 'application/json'
      request['Idempotency-Key'] = idempotency_key(mail)
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true,
                                open_timeout: 15, read_timeout: 25, write_timeout: 25) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise DeliveryError, "Resend rejected email delivery (HTTP #{response.code})"
      end

      result = JSON.parse(response.body)
      unless result.is_a?(Hash) && result['id'].is_a?(String) && !result['id'].empty?
        raise DeliveryError, 'Resend returned an invalid delivery receipt'
      end

      result
    rescue JSON::ParserError
      raise DeliveryError, 'Resend returned an invalid delivery receipt', cause: nil
    rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError
      raise DeliveryError, 'Resend connection failed; delivery can be retried', cause: nil
    end

    private

    def validate_settings!
      key = settings[:api_key]
      unless key.is_a?(String) && !key.strip.empty? && !key.match?(/[\r\n]/)
        raise DeliveryError, 'Resend API key is missing or invalid'
      end

      from = settings[:from_email]
      unless from.is_a?(String) && !from.strip.empty? && !from.match?(/[\r\n]/)
        raise DeliveryError, 'Resend sender email is missing or invalid'
      end
    end

    def build_payload(mail)
      mail.message_id ||= "#{SecureRandom.uuid}@docuseal.local"
      payload = { from: settings.fetch(:from_email), subject: mail.subject.to_s }
      ADDRESS_FIELDS.each do |field|
        addresses = Array(mail.public_send(field))
        payload[field] = addresses unless addresses.empty?
      end
      unless %i[to cc bcc].any? { |field| payload[field]&.any? }
        raise DeliveryError, 'Resend email must have at least one recipient'
      end
      if %i[to cc bcc].sum { |field| Array(payload[field]).size } > 50
        raise DeliveryError, 'Resend email exceeds the 50 recipient limit'
      end

      add_body(payload, mail)
      payload[:headers] = HEADER_NAMES.to_h { |name| [name, mail[name]&.to_s] }.compact
      payload[:attachments] = mail.attachments.map { |part| attachment_payload(part) } if mail.attachments.any?
      payload
    end

    def add_body(payload, mail)
      if mail.multipart?
        payload[:text] = mail.text_part.decoded if mail.text_part
        payload[:html] = mail.html_part.decoded if mail.html_part
      else
        payload[mail.mime_type == 'text/html' ? :html : :text] = mail.body.decoded
      end
      return if payload.key?(:text) || payload.key?(:html)

      raise DeliveryError, 'Resend email must have a text or HTML body'
    end

    def attachment_payload(part)
      payload = { filename: part.filename, content: Base64.strict_encode64(part.body.decoded),
                  content_type: part.mime_type }
      payload[:content_id] = part.cid if part.inline? && part.content_id
      payload
    end

    def idempotency_key(mail)
      metadata = mail.instance_variable_get(:@message_metadata) || {}
      token = metadata['idempotency_key'] || mail['X-Resend-Idempotency-Key']&.value || mail.message_id
      "docuseal/#{Digest::SHA256.hexdigest(token.to_s)}"
    end
  end
end
