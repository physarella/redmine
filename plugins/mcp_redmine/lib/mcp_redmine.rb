require 'base64'
require 'digest'
require 'json'
require 'securerandom'
require 'yaml'

module McpRedmine
  VERSION = '1.0.0'

  SPEC = YAML.safe_load_file(File.expand_path('../config/redmine-openapi.yml', __dir__))

  # Paths that must not be reached through redmine_request (the MCP endpoint itself and the OAuth flow)
  BLOCKED_PREFIXES = %w[mcp oauth .well-known].freeze

  # Name prefix of the OAuth applications created by dynamic client registration
  APPLICATION_PREFIX = 'MCP: '

  def self.settings
    Setting.plugin_mcp_redmine
  end

  def self.enabled?
    Setting.rest_api_enabled? && settings['enabled'] == '1'
  end

  # Every Redmine permission, without admin: anyone can register a client, so a token approved by an
  # administrator (e.g. through a phishing link) must not carry admin rights. The effective rights are still
  # limited to what the user can do. Admin tasks need the X-Redmine-API-Key header instead of OAuth.
  def self.scopes
    Redmine::AccessControl.permissions.map {|p| p.name.to_s}
  end

  WRITE_METHODS = %w[post put patch delete].freeze

  # Largest attachments whose content goes back in the tool result
  INLINE_TEXT_MAX = 1.megabyte
  INLINE_IMAGE_MAX = 5.megabytes

  # Reads and writes are separate tools so the client can let reads run and ask the user before every write
  def self.tools
    [
      {
        name: 'redmine_request',
        description: <<~DESC.strip + instructions_suffix,
          Read from the Redmine REST API with a GET request. To create, update or delete, use redmine_write.

          - path: API path ending in .json, e.g. /issues.json
          - params: optional query string parameters, e.g. {"project_id": "my-project", "status_id": "open"}

          The result has the HTTP status_code, the response body and an error message, if any.
        DESC
        inputSchema: {
          type: 'object',
          properties: {
            path: {type: 'string'},
            params: {type: ['object', 'null'], default: nil}
          },
          required: ['path']
        },
        annotations: {title: 'Read from Redmine', readOnlyHint: true, openWorldHint: false}
      },
      {
        name: 'redmine_write',
        description: <<~DESC.strip + instructions_suffix,
          Create, update or delete through the Redmine REST API.

          - path: API path ending in .json, e.g. /issues/123.json
          - method: post, put, patch or delete
          - data: request body for post, put and patch, e.g. {"issue": {"notes": "Done"}}
          - params: optional query string parameters

          The result has the HTTP status_code, the response body and an error message, if any.
        DESC
        inputSchema: {
          type: 'object',
          properties: {
            path: {type: 'string'},
            method: {type: 'string', enum: WRITE_METHODS},
            data: {type: ['object', 'null'], default: nil},
            params: {type: ['object', 'null'], default: nil}
          },
          required: ['path', 'method']
        },
        annotations: {title: 'Write to Redmine', readOnlyHint: false, destructiveHint: true, idempotentHint: false,
                      openWorldHint: false}
      },
      {
        name: 'redmine_download',
        description: <<~DESC.strip,
          Get an attachment (file) from Redmine.

          - attachment_id: ID of the attachment, as listed in 'attachments' of issues, wiki pages, files, etc.

          The result has the attachment's metadata and its Redmine URL, which the user can open in the browser to
          download the file. Text files up to 1 MB also come with their content, and images up to 5 MB come as an image.
        DESC
        inputSchema: {
          type: 'object',
          properties: {attachment_id: {type: 'integer'}},
          required: ['attachment_id']
        },
        annotations: {title: 'Download Redmine attachment', readOnlyHint: true, openWorldHint: false}
      },
      {
        name: 'redmine_upload',
        description: <<~DESC.strip,
          Upload a file to Redmine and get a token to attach it.

          - filename: file name, e.g. report.md
          - file_content: the content, as text or base64 (see encoding)
          - encoding: text (default) or base64 for binary content
          - content_type: optional MIME type, e.g. text/markdown
          - description: optional description of the file

          The result has the HTTP status_code, the response body with the token and an error message, if any.
          The file is not attached yet: attach it with redmine_write, e.g. PUT /issues/123.json with
          {"issue": {"uploads": [{"token": "...", "filename": "...", "content_type": "..."}]}}. The same
          'uploads' works for wiki pages, project files, documents, etc.
        DESC
        inputSchema: {
          type: 'object',
          properties: {
            filename: {type: 'string'},
            file_content: {type: 'string'},
            encoding: {type: 'string', enum: %w[text base64], default: 'text'},
            content_type: {type: ['string', 'null'], default: nil},
            description: {type: ['string', 'null'], default: nil}
          },
          required: ['filename', 'file_content']
        },
        annotations: {title: 'Upload file to Redmine', readOnlyHint: false, destructiveHint: false,
                      idempotentHint: false, openWorldHint: false}
      },
      {
        name: 'redmine_paths_list',
        description: <<~DESC.strip,
          List the paths of the Redmine REST API, e.g. /issues.json and /projects/{project_id}.json.

          Use redmine_paths_info to get the parameters and request body of the paths you need.
        DESC
        inputSchema: {type: 'object', properties: {}},
        annotations: {title: 'List Redmine API paths', readOnlyHint: true, openWorldHint: false}
      },
      {
        name: 'redmine_paths_info',
        description: <<~DESC.strip,
          Describe Redmine REST API paths: operations, parameters and request bodies, from its OpenAPI specification.

          - path_templates: paths as listed by redmine_paths_list, e.g. ["/issues.json", "/projects.json"]
        DESC
        inputSchema: {
          type: 'object',
          properties: {path_templates: {type: 'array', items: {type: 'string'}}},
          required: ['path_templates']
        },
        annotations: {title: 'Describe Redmine API paths', readOnlyHint: true, openWorldHint: false}
      }
    ]
  end

  def self.instructions_suffix
    settings['request_instructions'].present? ? "\n\n#{settings['request_instructions']}" : ''
  end

  # Changes when the tool list or descriptions change (plugin upgrade or new instructions for the model)
  def self.tools_version
    Digest::SHA256.hexdigest(tools.to_json)[0, 16]
  end

  # Runs a tool and returns its text result (or a list of MCP content items), or nil when the tool doesn't exist
  def self.call(name, args, request)
    case name
    when 'redmine_request'
      response = redmine_request(request, args['path'].to_s, 'get', nil, args['params'])
      wrap_insecure_content(format_response(response))
    when 'redmine_write'
      method = args['method'].to_s.downcase
      response =
        if WRITE_METHODS.include?(method)
          redmine_request(request, args['path'].to_s, method, args['data'], args['params'])
        else
          {'status_code' => 0, 'body' => nil, 'error' => "Invalid method: #{args['method']} (use #{WRITE_METHODS.join(', ')})"}
        end
      wrap_insecure_content(format_response(response))
    when 'redmine_download'
      download(args['attachment_id'])
    when 'redmine_upload'
      wrap_insecure_content(format_response(upload(args)))
    when 'redmine_paths_list'
      format_response(SPEC['paths'].keys)
    when 'redmine_paths_info'
      format_response(SPEC['paths'].slice(*Array(args['path_templates'])))
    end
  end

  # Metadata and Redmine URL of an attachment, plus its content when it is small text or an image
  def self.download(attachment_id)
    attachment = Attachment.find_by(id: attachment_id.to_i)
    unless attachment&.visible?(User.current)
      return format_response({'status_code' => 404, 'body' => nil, 'error' => "Attachment not found: #{attachment_id}"})
    end

    url = Rails.application.routes.url_helpers.download_named_attachment_url(
      attachment, attachment.filename, **Mailer.default_url_options)
    info = {'id' => attachment.id, 'filename' => attachment.filename, 'content_type' => attachment.content_type,
            'filesize' => attachment.filesize, 'description' => attachment.description, 'url' => url}
    readable = attachment.readable?

    if readable && attachment.is_text? && attachment.filesize <= INLINE_TEXT_MAX
      content = File.binread(attachment.diskfile).force_encoding('UTF-8').scrub
      return wrap_insecure_content(format_response({'status_code' => 200, 'body' => info.merge('content' => content), 'error' => ''}))
    end

    text = wrap_insecure_content(format_response({'status_code' => 200, 'body' => info, 'error' => ''}))
    if readable && attachment.is_image? && attachment.filesize <= INLINE_IMAGE_MAX
      mime_type = attachment.content_type.presence || Redmine::MimeType.of(attachment.filename)
      return [{type: 'text', text: text},
              {type: 'image', data: Base64.strict_encode64(File.binread(attachment.diskfile)), mimeType: mime_type}]
    end
    text
  end

  # Same flow as Redmine's AttachmentsController#upload, so its validations (size, extensions, filename) apply
  def self.upload(args)
    # Same check as AttachmentsController#upload (authorize_global), honoring the OAuth scope of User.current
    unless User.current.allowed_to?({controller: 'attachments', action: 'upload'}, nil, global: true)
      return {'status_code' => 403, 'body' => nil, 'error' => 'HTTPError: 403 Forbidden'}
    end

    content = args['file_content'].to_s
    content = Base64.strict_decode64(content) if args['encoding'] == 'base64'

    attachment = Attachment.new(file: StringIO.new(content))
    attachment.author = User.current
    attachment.filename = args['filename'].presence || Redmine::Utils.random_hex(16)
    attachment.content_type = args['content_type'].presence
    attachment.description = args['description'].to_s
    if attachment.save
      {'status_code' => 201, 'body' => {'upload' => {'id' => attachment.id, 'token' => attachment.token}}, 'error' => ''}
    else
      {'status_code' => 422, 'body' => {'errors' => attachment.errors.full_messages}, 'error' => 'Upload failed'}
    end
  rescue ArgumentError => e
    {'status_code' => 0, 'body' => nil, 'error' => "Invalid base64 content: #{e.message}"}
  end

  # Calls Redmine's own REST API in-process, with the credentials of the MCP request,
  # so Redmine applies the user's permissions and OAuth scopes exactly as for any API client
  def self.redmine_request(request, path, method, data, params)
    segments = path.sub(/\A\/+/, '').split('/')
    if segments.empty? || segments.include?('..') || path.include?('?') || !path.end_with?('.json') ||
       BLOCKED_PREFIXES.include?(segments.first.sub(/\.json\z/, ''))
      return {'status_code' => 0, 'body' => nil, 'error' => "Invalid path: #{path} (must be a Redmine API path ending in .json)"}
    end

    url = "#{request.script_name}/#{segments.join('/')}"
    url += "?#{params.to_query}" if params.present?
    env = Rack::MockRequest.env_for(url, method: method.upcase, input: data.nil? ? '' : data.to_json)
    env.merge!(
      'CONTENT_TYPE' => 'application/json',
      'HTTP_ACCEPT' => 'application/json',
      'HTTP_HOST' => request.host_with_port,
      'HTTPS' => request.ssl? ? 'on' : 'off',
      'rack.url_scheme' => request.scheme,
      'SCRIPT_NAME' => request.script_name,
      'PATH_INFO' => "/#{segments.join('/')}",
      'REMOTE_ADDR' => request.remote_ip
    )
    env['HTTP_AUTHORIZATION'] = request.authorization if request.authorization.present?
    env['HTTP_X_REDMINE_API_KEY'] = request.headers['X-Redmine-API-Key'] if request.headers['X-Redmine-API-Key'].present?

    # The nested request resets the per-request current attributes (User.current) when it finishes
    current_user = User.current
    status, headers, body = Rails.application.call(env)
    content = +''
    body.each {|part| content << part}
    body.close if body.respond_to?(:close)
    User.current = current_user

    parsed = begin
      content.empty? ? nil : JSON.parse(content)
    rescue JSON::ParserError
      content.force_encoding('UTF-8')
    end
    error = status >= 400 ? "HTTPError: #{status} #{Rack::Utils::HTTP_STATUS_CODES[status]}" : ''
    {'status_code' => status, 'body' => parsed, 'error' => error}
  rescue => e
    User.current = current_user if current_user
    {'status_code' => 0, 'body' => nil, 'error' => "#{e.class}: #{e.message}"}
  end

  def self.format_response(obj)
    if settings['response_format'] == 'json'
      JSON.pretty_generate(obj)
    else
      YAML.dump(obj, line_width: -1).delete_prefix("---\n")
    end
  end

  # Wraps content that may contain user-generated data with security tags to prevent prompt injection
  def self.wrap_insecure_content(content)
    tag_id = SecureRandom.hex(8)
    "<insecure-content-#{tag_id}>\n#{content}\n</insecure-content-#{tag_id}>"
  end
end
