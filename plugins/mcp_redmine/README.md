# MCP Redmine

English | [Português](README.pt-BR.md)

A Redmine plugin that runs an [MCP](https://modelcontextprotocol.io) server inside Redmine itself, at `/mcp`. AI
assistants (Claude, Copilot, ChatGPT, etc.) can then use **the whole Redmine REST API** on behalf of each user. For
example, the assistant can:

- search and read projects and issues;
- create and update issues, notes and statuses;
- log time;
- reach the rest of the API.

There is no separate server. Calls run inside Redmine, with the permissions of the user who connected.

## Requirements

- Redmine 6.1 or later, which ships the built-in OAuth2 provider. Tested on 6.1 and 7.0.
- REST API enabled in *Administration → Settings → API*.
- Redmine at the root of its host (e.g. `https://redmine.example.com`). MCP clients look for the OAuth metadata at
  `/.well-known/...` on the host root.

## Installation

```bash
cd /path/to/redmine/plugins
git clone https://github.com/gabera/mcp_redmine.git
# restart Redmine
```

The directory must be named `mcp_redmine`. The plugin has no migrations and no extra gems.

To update, run `git pull` in the plugin directory and restart Redmine.

Then, in *Administration → Plugins → MCP Redmine → Configure*, set:

| Option | Description |
|---|---|
| Enable MCP endpoint | Turns on `/mcp`, the OAuth metadata and client registration. Off by default |
| Response format | `yaml` (default) or `json` |
| Instructions for the model | Guidance such as "use Textile", project ids and required fields. Sent as the MCP server `instructions`, which clients put in the system prompt, and appended to the description of the `redmine_request` and `redmine_write` tools |

The instructions guide the model but do not bind it. Do not rely on them for rules that must hold, such as asking
before changing data: use the client's permissions for that (see [Tools](#tools)).

Changes to the instructions take effect without restarting Redmine or disconnecting anyone:
- The server `instructions` are read on connect, so they apply to new sessions.
- In open sessions, the tool descriptions are updated: the client receives `notifications/tools/list_changed` with
  the response to its next call.
- Claude Desktop ignores that notification and only picks up the new text when it reconnects.

## Connecting clients

All clients only need the URL `https://<your-redmine>/mcp`. On the first connection, the browser opens the Redmine
login and the application authorization page.

- **Claude Code:**
  ```bash
  claude mcp add --transport http redmine https://<your-redmine>/mcp
  ```
  Then run `/mcp`, choose `redmine` and click *Authenticate*.
- **Claude Desktop / claude.ai:** *Settings → Connectors → Add custom connector*, with the URL.
- **GitHub Copilot (VS Code):** run *MCP: Open User Configuration* and add
  `{ "servers": { "redmine": { "type": "http", "url": "https://<your-redmine>/mcp" } } }`.
- **Without OAuth:** you can also send your personal API key in the `X-Redmine-API-Key` header.

## How authentication works

The plugin uses Redmine's own OAuth2 provider (Doorkeeper) and adds what MCP clients need:

1. The client calls `/mcp` and gets `401` with the address of `/.well-known/oauth-protected-resource`.
2. At `/.well-known/oauth-authorization-server`, the client finds `/oauth/authorize`, `/oauth/token` and
   `/mcp/register`.
3. The client registers itself (dynamic client registration, public client with PKCE). The application shows up in
   *Administration → Applications* as `MCP: <client name> (<redirect host>)`, e.g. `MCP: Claude Code (localhost)`.
4. The user logs in to Redmine and authorizes the application. The token lasts 2 hours and is renewed with the
   refresh token. Users can revoke access in *My account → Authorized applications*.

The token gets every Redmine permission as its scope. Even so, the result never goes beyond what the user can do:
Redmine applies the permissions of each user's roles on every call.

**Security.** Anyone can register a client, as MCP requires, so a malicious link could ask a user to authorize an
application that sends the token elsewhere. Two things limit this:
- The consent page shows the host the token goes to, in the application name. Users should only authorize
  applications whose host they recognize (`localhost`, `claude.ai`, etc.).
- OAuth tokens never get the `admin` scope, so an administrator who authorizes a client does not hand over admin
  rights. Admin-only API calls (creating users, groups, roles, etc.) are not available through OAuth: for them, use
  the `X-Redmine-API-Key` header.

Administrators can review and delete the registered applications in *Administration → Applications*.

## Tools

- **`redmine_request`**: reads from the Redmine API (GET). Marked as read-only.
  - Parameters: `path` (e.g. `/issues.json`) and `params` (query string).
- **`redmine_write`**: creates, updates or deletes through the Redmine API. Marked as a write.
  - Parameters: `path` (e.g. `/issues/123.json`), `method` (`post`, `put`, `patch` or `delete`), `data` (body)
    and `params` (query string).
- **`redmine_download`**: gets an attachment. Marked as read-only.
  - Parameter: `attachment_id`.
  - Returns the name, type, size, description and the Redmine link of the attachment, so the user can download it in
    the browser (logged in).
  - Text files up to 1 MB also come with their content, and images up to 5 MB come as an image, so the assistant can
    read them. Other types (PDF, zip, etc.) come with the data and the link only.
- **`redmine_upload`**: uploads a file and returns the `token` to attach it. Marked as a write.
  - Parameters: `filename`, `file_content`, `encoding` (`text`, the default, or `base64`), `content_type` and
    `description`.
  - Redmine's limits apply: maximum size and allowed extensions.
- **`redmine_paths_list`**: lists the paths of the Redmine OpenAPI specification.
- **`redmine_paths_info`**: returns the full specification of the given paths (e.g. `["/issues.json"]`).

`redmine_request` and `redmine_write` return `status_code`, `body` and `error`, and only accept API paths ending in
`.json`.

**Attaching files.** Uploading takes two steps, as in the Redmine API:
1. `redmine_upload` sends the content and returns a `token`.
2. `redmine_write` attaches the file with `uploads`, for example `PUT /issues/123.json` with
   `{"issue": {"uploads": [{"token": "...", "filename": "report.md"}]}}`. The same `uploads` works for wiki pages,
   project files, documents, etc.

Files uploaded but never attached stay in Redmine until its prune task removes them (unattached for over a day).
Redmine does not schedule it, so add a daily cron job:
`bundle exec rake redmine:attachments:prune RAILS_ENV=production`.

The content goes inside the tool call, so the assistant can only upload what it generates or can rewrite itself:
text, markdown, csv, code. Binary files on the user's computer (PDF, screenshots, zip) must be attached through the
Redmine web UI, because the plugin runs in Redmine and cannot reach the user's disk.

**Confirmation before changing data.** Reads and writes are separate tools so the client can ask for approval
before every write. In Claude Desktop and claude.ai:
1. Open *Settings → Connectors* and choose Redmine.
2. Set the read tools to *Always allow* and `redmine_write` to *Always ask*.

Every write then shows the call, with its data, for the user to approve. This holds even if the model ignores the
instructions.

Example prompts:

- "List the open high-priority issues in project X that have no assignee."
- "Move issue #123 to *In Progress* and add the note: 'Started, due Friday'."
- "Log 3.5 hours on issue #456 today, activity 'Development'."

## Local development

`docker-compose.yml` starts Redmine 6.1.5 with PostgreSQL and this repository mounted as a plugin:

```bash
docker compose up -d   # http://localhost:3000, login admin/admin
```

1. Enable the REST API and the plugin.
2. Connect the client to `http://localhost:3000/mcp`. `http://localhost` redirect URIs are accepted.
3. The container runs in production mode and does not reload code: after editing the plugin, run
   `docker compose restart redmine`.

## License and credits

Distributed under the [Apache License 2.0](LICENSE).

Based on [mcp-redmine](https://github.com/runekaagaard/mcp-redmine) by Rune Kaagaard, an MCP server written in
Python. The OpenAPI specification in `config/redmine-openapi.yml` comes from
[d-yoshi/redmine-openapi](https://github.com/d-yoshi/redmine-openapi) (MIT), with descriptions revised for language
models.
