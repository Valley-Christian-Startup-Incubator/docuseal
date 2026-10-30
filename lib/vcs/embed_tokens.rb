# frozen_string_literal: true

require 'uri'

module Vcs
  module EmbedTokens
    PURPOSE = 'vcs-template-builder'
    TTL = 1.hour
    DEFAULT_ORIGINS = %w[https://valleychristianai.com https://*.valleychristianai.com https://vcs.net https://*.vcs.net].freeze

    module_function

    def origin(value)
      uri = URI.parse(value.to_s)
      valid_scheme = uri.scheme == 'https' || (uri.scheme == 'http' && %w[localhost 127.0.0.1 [::1]].include?(uri.host))
      raise ArgumentError, 'A valid HTTPS origin is required' unless valid_scheme && uri.host.present?
      hostname = uri.hostname
      valid_host = hostname == '::1' || (hostname.length <= 253 && hostname.split('.').all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i) })
      raise ArgumentError, 'A valid exact origin is required' unless valid_host && uri.port.between?(1, 65_535)
      raise ArgumentError, 'Provide an origin without a path, query or credentials' if uri.userinfo || uri.query || uri.fragment || uri.path.present?

      uri.to_s
    rescue URI::InvalidURIError
      raise ArgumentError, 'Invalid origin'
    end

    def issue(user:, template:, origin:)
      raise CanCan::AccessDenied unless allowed?(user, template)

      Rails.application.message_verifier(PURPOSE).generate(
        { 'user_id' => user.id, 'template_id' => template.id, 'origin' => self.origin(origin) },
        purpose: PURPOSE, expires_in: TTL
      )
    end

    def verify(token)
      payload = Rails.application.message_verifier(PURPOSE).verified(token.to_s, purpose: PURPOSE)
      return unless payload.is_a?(Hash)
      return unless payload['user_id'].is_a?(Integer) && payload['template_id'].is_a?(Integer)
      return unless origin(payload['origin']) == payload['origin']

      payload
    rescue ArgumentError
      nil
    end

    def allowed?(user, template)
      user && template && !user.archived_at? && !user.account.archived_at? &&
        user.role != User::VIEWER_ROLE && !template.archived_at? && Ability.new(user).can?(:update, template)
    end

    def signing_origins
      ENV.fetch('VCS_EMBED_ORIGINS', DEFAULT_ORIGINS.join(' ')).split.filter_map do |value|
        candidate = value.sub('https://*.', 'https://')
        origin(candidate)
        value
      rescue ArgumentError
        nil
      end
    end
  end
end
