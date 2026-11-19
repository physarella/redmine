Redmine::Plugin.register :mcp_redmine do
  name 'MCP Redmine'
  author 'gabera'
  description 'MCP (Model Context Protocol) server inside Redmine: AI assistants (Claude, ChatGPT, Copilot) use the ' \
              'whole REST API through OAuth, with each user\'s own permissions'
  version McpRedmine::VERSION
  url 'https://github.com/gabera/mcp_redmine'
  author_url 'https://github.com/gabera'
  requires_redmine version_or_higher: '6.1.0'

  settings default: {'enabled' => '0', 'response_format' => 'yaml', 'request_instructions' => ''},
           partial: 'settings/mcp_redmine'
end

# File content sent to redmine_upload must not end up in the Redmine log
Rails.application.config.filter_parameters += [:file_content]

# MCP clients that don't send a scope would get only Redmine's public permissions: use the scopes the
# application was registered with instead. Deferred so the controller loads after Redmine configures Doorkeeper.
Rails.application.config.after_initialize do
  Doorkeeper::AuthorizationsController.before_action only: :new do
    next if params[:scope].present?

    application = Doorkeeper::Application.by_uid(params[:client_id].to_s)
    params[:scope] = application.scopes.to_s if application&.name&.start_with?(McpRedmine::APPLICATION_PREFIX)
  end
end
