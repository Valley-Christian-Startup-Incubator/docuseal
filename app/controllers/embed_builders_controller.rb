# frozen_string_literal: true

class EmbedBuildersController < ApplicationController
  def show
    return head :unauthorized unless vcs_embed_authenticated?

    @template = Template.find(@vcs_embed_payload.fetch('template_id'))
    authorize!(:update, @template)
    @template_data = Templates.serialize_for_builder(@template)

    render :show, layout: 'plain'
  end
end
