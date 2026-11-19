# Stateless MCP endpoint (Streamable HTTP). Responses are JSON, or SSE when the tools changed since the session
# started: the session id carries the tools version, so the next request of that session gets
# notifications/tools/list_changed before its response.
class McpController < ApplicationController
  PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26].freeze
  SESSION_HEADER = 'Mcp-Session-Id'

  accept_api_auth :handle
  skip_before_action :check_if_login_required
  before_action :require_mcp_user

  def handle
    return head(:method_not_allowed, 'Allow' => 'POST') unless request.post?
    # A cross-site form can't send application/json without a CORS preflight, which Redmine doesn't allow
    unless request.media_type == 'application/json'
      return render(json: rpc_error(nil, -32600, 'Content-Type must be application/json'), status: :unsupported_media_type)
    end
    # Uploads come as base64 in the JSON body: refuse anything far bigger than Redmine accepts before parsing it
    if (request.content_length || request.raw_post.bytesize) > max_body_size
      return render(json: rpc_error(nil, -32600, 'Request too large'), status: :content_too_large)
    end

    message = JSON.parse(request.raw_post) rescue nil
    unless message.is_a?(Hash) && message['jsonrpc'] == '2.0' && message['method'].is_a?(String)
      return render(json: rpc_error(nil, -32600, 'Invalid Request'), status: :bad_request)
    end
    # Notifications and responses from the client need no answer
    return head(:accepted) unless message.key?('id')

    result = handle_rpc(message['id'], message['method'], message['params'] || {})
    if message['method'] == 'initialize'
      response.headers[SESSION_HEADER] = "#{McpRedmine.tools_version}.#{SecureRandom.hex(16)}"
    elsif notify_tools_changed?
      events = [{jsonrpc: '2.0', method: 'notifications/tools/list_changed'}, result]
      return render(plain: events.map {|e| "event: message\ndata: #{e.to_json}\n\n"}.join,
                    content_type: 'text/event-stream')
    end
    render json: result
  end

  private

  def handle_rpc(id, method, params)
    case method
    when 'initialize'
      version = PROTOCOL_VERSIONS.include?(params['protocolVersion']) ? params['protocolVersion'] : PROTOCOL_VERSIONS.first
      # Clients put the server instructions in the system prompt, where they weigh more than a tool description
      instructions = McpRedmine.settings['request_instructions'].presence
      rpc_result(id, {protocolVersion: version, capabilities: {tools: {listChanged: true}},
                      serverInfo: {name: 'Redmine MCP server', version: McpRedmine::VERSION},
                      instructions: instructions}.compact)
    when 'ping'
      rpc_result(id, {})
    when 'tools/list'
      rpc_result(id, tools: McpRedmine.tools)
    when 'tools/call'
      content = McpRedmine.call(params['name'], params['arguments'] || {}, request)
      return rpc_error(id, -32602, "Unknown tool: #{params['name']}") if content.nil?

      content = [{type: 'text', text: content}] unless content.is_a?(Array)
      rpc_result(id, content: content, isError: false)
    else
      rpc_error(id, -32601, "Method not found: #{method}")
    end
  end

  # True once per session (and per Redmine process) after the tools changed, e.g. new instructions for the model
  def notify_tools_changed?
    session_id = request.headers[SESSION_HEADER].to_s
    version = McpRedmine.tools_version
    return false if session_id.split('.').first.in?(['', version]) || !request.accept.to_s.include?('text/event-stream')

    key = "mcp_redmine/notified/#{session_id}"
    return false if Rails.cache.read(key) == version

    Rails.cache.write(key, version, expires_in: 1.day)
  end

  # Base64 makes content 4/3 bigger; the rest is room for the JSON-RPC envelope
  def max_body_size
    Setting.attachment_max_size.to_i.kilobytes * 4 / 3 + 64.kilobytes
  end

  def rpc_result(id, result)
    {jsonrpc: '2.0', id: id, result: result}
  end

  def rpc_error(id, code, message)
    {jsonrpc: '2.0', id: id, error: {code: code, message: message}}
  end

  def require_mcp_user
    return render_404 unless McpRedmine.enabled?
    return if User.current.logged?

    metadata_url = "#{request.base_url}#{request.script_name}/.well-known/oauth-protected-resource"
    response.headers['WWW-Authenticate'] =
      %(Bearer resource_metadata="#{metadata_url}", scope="#{McpRedmine.scopes.join(' ')}")
    render json: rpc_error(nil, -32001, 'Unauthorized'), status: :unauthorized
  end
end
