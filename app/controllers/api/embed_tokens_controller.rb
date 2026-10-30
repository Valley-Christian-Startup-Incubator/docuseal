# frozen_string_literal: true

module Api
  class EmbedTokensController < ApiBaseController
    def create
      template = Template.find(params.require(:template_id))
      authorize!(:update, template)
      token = Vcs::EmbedTokens.issue(user: current_user, template:, origin: params.require(:origin))

      response.headers['Cache-Control'] = 'no-store'
      render json: { token:, expires_in: Vcs::EmbedTokens::TTL.to_i,
                     src: embed_builder_url(template, token:) }
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end
