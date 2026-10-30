# frozen_string_literal: true

module ActionMailerConfigsInterceptor
  OPEN_TIMEOUT = ENV.fetch('SMTP_OPEN_TIMEOUT', '15').to_i
  READ_TIMEOUT = ENV.fetch('SMTP_READ_TIMEOUT', '25').to_i

  module_function

  def delivering_email(message)
    return message unless Rails.env.production?

    if (job_id = Thread.current[:vcs_mail_job_id])
      metadata = message.instance_variable_get(:@message_metadata) || {}
      identity = [job_id, metadata['tag'], metadata['record_type'], metadata['record_id'], *Array(message.to), *Array(message.cc), *Array(message.bcc)].join(':')
      Vcs::MailIdentity.apply(message, identity) unless metadata['idempotency_key'].present?
    end

    if Docuseal.demo?
      message.delivery_method(:test)

      return message
    end

    unless Docuseal.multitenant?
      resend_config = EncryptedConfig.order(:account_id).find_by(key: 'resend_api')

      if resend_config
        value = resend_config.value
        from = %("#{resend_config.account.name.to_s.delete('"')}" <#{value['from_email']}>)
        message.from = from
        message.delivery_method(Vcs::ResendDelivery, value.merge('from_email' => from))

        return message
      end
    end

    if Rails.env.production? && Rails.application.config.action_mailer.delivery_method
      from = ENV.fetch('SMTP_FROM').to_s.split(',').sample

      if from.match?(User::FULL_EMAIL_REGEXP)
        message[:from] = message[:from].to_s.sub(User::EMAIL_REGEXP, from)
      else
        message.from = from
      end

      return message
    end

    unless Docuseal.multitenant?
      email_configs = EncryptedConfig.order(:account_id).find_by(key: EncryptedConfig::EMAIL_SMTP_KEY)

      if email_configs
        message.delivery_method(:smtp, build_smtp_configs_hash(email_configs))

        message.from = %("#{email_configs.account.name.to_s.delete('"')}" <#{email_configs.value['from_email']}>)
      else
        message.delivery_method(:test)
      end
    end

    message
  end

  def build_smtp_configs_hash(email_configs)
    value = email_configs.value

    is_tls = value['security'] == 'tls' || (value['security'].blank? && value['port'].to_s == '465')
    is_ssl = value['security'] == 'ssl'
    is_noverify = value['security'] == 'noverify'

    enable_starttls = is_noverify ? :enable_starttls_auto : :enable_starttls

    {
      user_name: value['username'],
      password: value['password'],
      address: value['host'],
      port: value['port'],
      domain: value['domain'],
      openssl_verify_mode: is_noverify ? OpenSSL::SSL::VERIFY_NONE : nil,
      authentication: value['password'].present? ? value.fetch('authentication', 'plain') : nil,
      enable_starttls => !is_tls && !is_ssl,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      ssl: is_ssl,
      tls: is_tls
    }.compact_blank
  end
end
