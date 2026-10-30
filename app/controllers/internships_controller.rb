# frozen_string_literal: true

class InternshipsController < ApplicationController
  layout 'form'
  skip_before_action :authenticate_user!
  skip_authorization_check
  before_action :load_packet, only: %i[show create]
  after_action :prevent_caching

  def show
    @intake = {}
    @errors = []
    prepare_token
  end

  def create
    @intake = Vcs::InternshipPacket.normalize(params.require(:intake).permit(*Vcs::InternshipPacket::INPUT_KEYS).to_h)
    @errors = Vcs::InternshipPacket.validate(@intake)
    unless @available && @errors.empty?
      prepare_token
      return render :show, status: @available ? :unprocessable_content : :service_unavailable
    end
    submitter = Vcs::InternshipPacket.create!(config: @config, attrs: @intake, token: params[:form_token],
      session_key: session[:internship_session_key], request:)
    redirect_to submit_form_path(submitter.slug), status: :see_other
  rescue Vcs::InternshipPacket::Error, Submissions::CreateFromSubmitters::BaseError => e
    @errors = [e.message]
    prepare_token
    render :show, status: :unprocessable_content
  rescue RateLimit::LimitApproached
    @errors = ['Too many packet requests. Please wait before starting another packet.']
    prepare_token
    render :show, status: :too_many_requests
  end

  def parent_signing
    student = Submitter.find_by!(slug: params[:student_slug])
    unless Submitters::AuthorizedForForm.call(student, current_user, request)
      return head :forbidden
    end
    parent = Vcs::InternshipPacket.parent_for(student)
    return head :not_found unless parent

    cookies.delete(:email_2fa_slug, **Submitters::StartForm::COOKIES_DEFAULTS)
    cookies.delete(:phone_2fa_slug, **Submitters::StartForm::COOKIES_DEFAULTS)
    redirect_to submit_form_path(parent.slug), status: :see_other
  end

  private

  def load_packet
    @config = Vcs::InternshipPacket.configuration
    @template = Vcs::InternshipPacket.template_for(@config)
    @available = @template.present?
  end

  def prepare_token
    session[:internship_session_key] ||= SecureRandom.hex(24)
    @form_token = Vcs::InternshipPacket.form_token(session[:internship_session_key])
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store, private'
    response.headers['Referrer-Policy'] = 'same-origin'
    response.headers['X-Robots-Tag'] = 'noindex, nofollow'
  end
end
