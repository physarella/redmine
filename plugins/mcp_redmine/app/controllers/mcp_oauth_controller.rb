# OAuth discovery (RFC 9728, RFC 8414) and dynamic client registration (RFC 7591) on top of Redmine's own
# OAuth2 provider, so MCP clients connect with just the /mcp URL
class McpOauthController < ActionController::API
  MAX_REDIRECT_URIS = 5
  MAX_HOST_LIST = 140

  before_action { head(:not_found) unless McpRedmine.enabled? }
  # The URLs come from the request's Host header: keep these responses out of shared caches
  after_action { response.headers['Cache-Control'] = 'no-store' }

  def protected_resource
    render json: {
      resource: "#{base_url}/mcp",
      authorization_servers: [base_url],
      scopes_supported: McpRedmine.scopes,
      bearer_methods_supported: ['header']
    }
  end

  def authorization_server
    render json: {
      issuer: base_url,
      authorization_endpoint: "#{base_url}/oauth/authorize",
      token_endpoint: "#{base_url}/oauth/token",
      revocation_endpoint: "#{base_url}/oauth/revoke",
      registration_endpoint: "#{base_url}/mcp/register",
      scopes_supported: McpRedmine.scopes,
      response_types_supported: ['code'],
      grant_types_supported: %w[authorization_code refresh_token],
      code_challenge_methods_supported: ['S256'],
      token_endpoint_auth_methods_supported: ['none']
    }
  end

  # Registers a public client (PKCE, no secret); it shows up in Administration > Applications
  def register
    metadata = JSON.parse(request.raw_post) rescue {}
    redirect_uris = Array(metadata['redirect_uris']).map(&:to_s)
    # Anyone can register a client: the redirect hosts in the name show on the consent screen where the code goes.
    # Every stored URI must yield a host (Doorkeeper splits the stored list on whitespace), and the client name
    # keeps only ASCII letters, digits and basic punctuation, so it can't fake the host part.
    # The host list is never truncated: registrations whose hosts don't fit in the name are refused.
    # Redmine's Doorkeeper config refuses javascript/data/vbscript URIs and http other than localhost.
    hosts = redirect_uris.map {|uri| redirect_host(uri)}
    host_list = hosts.uniq.join(', ')
    if redirect_uris.empty? || redirect_uris.size > MAX_REDIRECT_URIS || hosts.include?(nil) ||
       host_list.length > MAX_HOST_LIST
      return render(json: {error: 'invalid_redirect_uri',
                           error_description: "redirect_uris must have 1 to #{MAX_REDIRECT_URIS} absolute URIs with a " \
                                              "host and no whitespace, with hosts up to #{MAX_HOST_LIST} characters"},
                    status: :bad_request)
    end

    name = metadata['client_name'].to_s.gsub(/[^A-Za-z0-9 .,_\-]/, ' ').squish.presence || 'MCP client'
    application = Doorkeeper::Application.new(name: "#{McpRedmine::APPLICATION_PREFIX}#{name.truncate(100)} (#{host_list})",
                                              redirect_uri: redirect_uris.join("\n"),
                                              scopes: McpRedmine.scopes.join(' '), confidential: false)
    unless application.save
      return render(json: {error: 'invalid_redirect_uri',
                           error_description: application.errors.full_messages.join(', ').presence || 'redirect_uris is required'},
                    status: :bad_request)
    end

    render status: :created, json: {
      client_id: application.uid,
      client_id_issued_at: application.created_at.to_i,
      client_name: name,
      redirect_uris: redirect_uris,
      grant_types: %w[authorization_code refresh_token],
      response_types: ['code'],
      token_endpoint_auth_method: 'none',
      scope: application.scopes.to_s
    }
  end

  private

  # Where an absolute redirect URI sends the code: its host, with the scheme for app schemes (e.g. cursor://host).
  # nil if it has whitespace, doesn't parse or has no host.
  def redirect_host(uri)
    return nil if uri.match?(/\s/)

    parsed = URI.parse(uri)
    return nil if parsed.host.blank?

    %w[http https].include?(parsed.scheme.to_s.downcase) ? parsed.host : "#{parsed.scheme}://#{parsed.host}"
  rescue URI::InvalidURIError
    nil
  end

  def base_url
    "#{request.base_url}#{request.script_name}"
  end
end
