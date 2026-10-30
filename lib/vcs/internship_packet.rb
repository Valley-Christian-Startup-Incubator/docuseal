# frozen_string_literal: true

module Vcs
  module InternshipPacket
    CONFIG_KEY = 'vcs_internship'
    TOKEN_PURPOSE = 'internship-start'
    INPUT_KEYS = %w[student_name student_email parent_name parent_email host_name host_email host_organization host_title].freeze
    Error = Class.new(StandardError)
    module_function

    def configuration
      AccountConfig.find_by(key: CONFIG_KEY)
    end

    def template_for(config)
      return unless config&.value.is_a?(Hash) && config.value['enabled'] == true
      template = Template.find_by(id: config.value['template_id'], account_id: config.account_id, archived_at: nil)
      return unless template && !template.account.archived_at? && template.preferences['vcs_internship'] == true
      return unless template.author && !template.author.archived_at?
      return unless %w[student parent host school].all? { |key| template.submitters.any? { |role| role['vcs_role'] == key } }
      school = config.value['school_email'].to_s
      return unless school.match?(User::FULL_EMAIL_REGEXP)
      if template.submitters.any? { |role| role['vcs_role'] == 'issuer' }
        return unless config.value['issuer_email'].to_s.match?(User::FULL_EMAIL_REGEXP)
      end
      template
    end

    def form_token(session_key)
      Rails.application.message_verifier(TOKEN_PURPOSE).generate(
        { 'nonce' => SecureRandom.uuid, 'session_key' => session_key }, purpose: TOKEN_PURPOSE, expires_in: 1.hour
      )
    end

    def student?(submitter)
      submitter.metadata['vcs_internship'] == true && submitter.metadata['vcs_role'] == 'student' &&
        submitter.submission.template&.preferences&.dig('vcs_internship') == true
    end

    def parent_for(student)
      return unless student?(student) && student.completed_at?
      submission = student.submission
      return if student.account.archived_at? || submission.archived_at? || submission.expired?
      return if submission.template.archived_at? || student.declined_at?

      parent = submission.submitters.find do |person|
        person.metadata['vcs_internship'] == true && person.metadata['vcs_role'] == 'parent'
      end
      return unless parent && !parent.completed_at? && !parent.declined_at?
      return unless Submitters.current_submitter_order?(parent)

      parent
    end

    def normalize(input)
      INPUT_KEYS.index_with { |key| input[key].to_s.strip.first(key.end_with?('_email') ? 254 : 160) }
                .tap { |attrs| %w[student_email parent_email host_email].each { |key| attrs[key] = attrs[key].downcase } }
    end

    def validate(attrs)
      errors = []
      (INPUT_KEYS - ['host_title']).each do |key|
        errors << "#{key.humanize} is required." if attrs[key].blank?
      end
      %w[student_email parent_email host_email].each do |key|
        errors << "Enter a valid #{key.humanize.downcase}." unless attrs[key].match?(User::FULL_EMAIL_REGEXP)
      end
      if %w[student_email parent_email host_email].map { |key| attrs[key] }.uniq.size != 3
        errors << 'Student, parent or guardian, and host must have separate email addresses.'
      end
      errors
    end

    def create!(config:, attrs:, token:, session_key:, request:)
      payload = Rails.application.message_verifier(TOKEN_PURPOSE).verified(token.to_s, purpose: TOKEN_PURPOSE)
      unless payload.is_a?(Hash) && payload['session_key'] == session_key && payload['nonce'].present?
        raise Error, 'This form has expired. Reload the internship page and try again.'
      end
      errors = validate(attrs)
      raise Error, errors.join(' ') if errors.any?
      key = Digest::SHA256.hexdigest(payload.fetch('nonce'))

      submission = config.with_lock do
        template = template_for(config)
        raise Error, 'The internship packet is not available yet.' unless template
        previous = config.value.fetch('starts', {})[key]
        if previous
          existing = template.submissions.find_by(id: previous['submission_id'])
          raise Error, 'This packet is no longer available. Start again from the internship page.' unless existing && !existing.archived_at?
          next existing
        end
        if %w[student_email parent_email host_email].any? { |field| attrs[field] == config.value['school_email'].to_s.downcase || attrs[field] == config.value['issuer_email'].to_s.downcase }
          raise Error, 'Participant addresses must differ from the school signer address.'
        end
        RateLimit.call("internship-ip-#{Digest::SHA256.hexdigest(request.remote_ip)}", limit: 30, ttl: 1.hour, enabled: true)
        RateLimit.call("internship-email-#{Digest::SHA256.hexdigest(attrs.fetch('student_email'))}", limit: 3, ttl: 24.hours, enabled: true)
        recipients = template.submitters.map do |role|
          kind = role.fetch('vcs_role')
          email = case kind
                  when 'student', 'parent', 'host' then attrs.fetch("#{kind}_email")
                  when 'school' then config.value.fetch('school_email')
                  when 'issuer' then config.value.fetch('issuer_email')
                  end
          name = if %w[student parent host].include?(kind)
                   attrs.fetch("#{kind}_name")
                 else
                   config.value["#{kind}_name"].presence || role.fetch('name')
                 end
          values = template.fields.select { |f| f['submitter_uuid'] == role['uuid'] }.each_with_object({}) do |field, acc|
            input_key = field.dig('preferences', 'vcs_intake_key')
            acc[field['uuid']] = attrs[input_key] if input_key && attrs[input_key].present?
          end
          { 'uuid' => role['uuid'], 'email' => email, 'name' => name, 'values' => values,
            'metadata' => { 'vcs_internship' => true, 'vcs_role' => kind }, 'require_email_2fa' => true }
        end
        data = [{ 'submitters' => recipients }].map(&:with_indifferent_access)
        data, _, new_fields = Submissions::NormalizeParamUtils.normalize_submissions_params!(data, template, add_fields: false)
        created = Submissions.create_from_submitters(template:, user: template.author, source: :link,
          submitters_order: 'preserved', submissions_attrs: data, new_fields:,
          params: { 'send_email' => true, 'send_completed_email' => false }).first
        raise Error, 'Unable to prepare the internship packet.' unless created
        created.update!(name: 'Summer 2027 internship packet')
        created.submitters.find_by!(uuid: template.submitters.find { |r| r['vcs_role'] == 'student' }.fetch('uuid'))
               .update!(sent_at: nil)
        starts = config.value.fetch('starts', {}).merge(key => { 'submission_id' => created.id, 'created_at' => Time.current.to_i })
        config.update!(value: config.value.merge('starts' => starts))
        created
      end
      SearchEntries.enqueue_reindex(submission)
      submission.submitters.find_by!(uuid: submission.template_submitters.find { |role| role['vcs_role'] == 'student' }.fetch('uuid'))
    end

    def assign_signer_name(submitter)
      return unless submitter.metadata['vcs_internship'] == true
      field = submitter.submission.template_fields.find do |item|
        item['submitter_uuid'] == submitter.uuid && item.dig('preferences', 'vcs_identity') == 'name'
      end
      name = submitter.values[field['uuid']].to_s.strip if field
      submitter.name = name.first(160) if name.present?
    end
  end
end
