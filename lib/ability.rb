# frozen_string_literal: true

class Ability
  include CanCan::Ability

  def initialize(user)
    can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
    end

    can :destroy, Template, account_id: user.account_id
    can :manage, TemplateFolder, account_id: user.account_id
    can :manage, TemplateSharing, template: { account_id: user.account_id }
    can :manage, Submission, account_id: user.account_id
    can :manage, Submitter, account_id: user.account_id
    can :manage, User, account_id: user.account_id
    can :manage, EncryptedConfig, account_id: user.account_id
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, AccountConfig, account_id: user.account_id
    can :manage, UserConfig, user_id: user.id
    can :manage, Account, id: user.account_id
    can :manage, AccessToken, user_id: user.id
    can :manage, McpToken, user_id: user.id
    can :manage, WebhookUrl, account_id: user.account_id

    can :manage, :mcp
    can :manage, %i[bulk_send sms_verification custom_logo email_reminders personalization_advanced reply_to
                    resend_all download_users event_log_download disable_decline]

    unless user.role == User::ADMIN_ROLE
      cannot :manage, [User, Account, AccountConfig, EncryptedConfig, WebhookUrl, TemplateSharing]
      cannot :manage, :mcp
      cannot :manage, %i[custom_logo email_reminders personalization_advanced download_users]
      if user.role == User::VIEWER_ROLE
        cannot :manage, [Template, TemplateFolder, Submission, Submitter, AccessToken, McpToken]
        can :read, [Template, TemplateFolder, Submission, Submitter], account_id: user.account_id
      end
    end
  end
end
