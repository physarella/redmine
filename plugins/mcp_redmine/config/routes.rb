match 'mcp', to: 'mcp#handle', via: [:get, :post, :delete], defaults: {format: 'json'}
post 'mcp/register', to: 'mcp_oauth#register'
get '.well-known/oauth-protected-resource(/mcp)', to: 'mcp_oauth#protected_resource'
get '.well-known/oauth-authorization-server', to: 'mcp_oauth#authorization_server'
