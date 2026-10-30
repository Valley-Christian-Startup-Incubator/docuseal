# frozen_string_literal: true
class AccountLogosController < ApplicationController
  before_action { authorize!(:update, current_account) }

  def create
    file = params.require(:logo)
    data = file.read(2.megabytes + 1)
    type = Marcel::MimeType.for(StringIO.new(data))
    unless data.bytesize <= 2.megabytes && %w[image/png image/jpeg image/webp].include?(type)
      return redirect_to settings_personalization_path, alert: 'Choose a PNG, JPEG, or WebP logo up to 2 MB.'
    end
    current_account.logo.attach(io: StringIO.new(data), filename: file.original_filename, content_type: type)
    redirect_to settings_personalization_path, notice: 'Company logo saved.'
  end

  def destroy
    current_account.logo.purge_later
    redirect_to settings_personalization_path, notice: 'Default VCS logo restored.'
  end
end
