# frozen_string_literal: true

module VcsEmbedAuthentication
  extend ActiveSupport::Concern

  included do
    prepend_before_action :authenticate_vcs_embed!
    skip_before_action :verify_authenticity_token, if: :vcs_embed_authenticated?
    after_action :set_vcs_embed_headers
  end

  private

  def vcs_embed_authenticated?
    @vcs_embed_payload.present?
  end

  def authenticate_vcs_embed!
    token = request.headers['X-VCS-Embed-Token'].presence
    token ||= params[:token] if controller_name == 'embed_builders' && action_name == 'show'
    return unless token

    payload = Vcs::EmbedTokens.verify(token)
    return head :unauthorized unless payload && vcs_embed_route_allowed?(payload['template_id'])

    user = User.find_by(id: payload['user_id'])
    template = Template.find_by(id: payload['template_id'])
    return head :forbidden unless Vcs::EmbedTokens.allowed?(user, template)

    @vcs_embed_payload = payload
    sign_in(user, store: false)
  end

  def vcs_embed_route_allowed?(template_id)
    id = Regexp.escape(template_id.to_s)
    path = request.path
    return request.get? && params[:id].to_s == template_id.to_s if controller_name == 'embed_builders' && action_name == 'show'
    return request.patch? || request.put? if path.match?(%r{\A/templates/#{id}\z})
    return request.get? || request.post? if path.match?(%r{\A/templates/#{id}/(?:documents|documents_crop|versions)\z})
    return request.get? if path.match?(%r{\A/templates/#{id}/(?:documents_page_objects|versions/\d+)\z})
    return request.post? if path.match?(%r{\A/templates/#{id}/(?:documents_modify|detect_fields)\z})

    false
  end

  def set_vcs_embed_headers
    origins = if vcs_embed_authenticated?
                [@vcs_embed_payload.fetch('origin')]
              elsif params[:embed] == '1' && controller_name.start_with?('submit_form', 'start_form')
                Vcs::EmbedTokens.signing_origins
              end
    return if origins.nil?

    response.headers.delete('X-Frame-Options')
    request.content_security_policy = (request.content_security_policy || ActionDispatch::ContentSecurityPolicy.new).tap do |policy|
      policy.frame_ancestors(*(origins.presence || [:none]))
    end
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Cache-Control'] = 'no-store'
  end
end
