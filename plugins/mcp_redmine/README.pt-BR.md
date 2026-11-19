# MCP Redmine

[English](README.md) | Português

Plugin do Redmine que expõe um servidor [MCP](https://modelcontextprotocol.io) no próprio Redmine, em `/mcp`. Com
ele, assistentes de IA (Claude, Copilot, ChatGPT etc.) usam **toda a API REST do Redmine** em nome de cada usuário.
Por exemplo, o assistente pode:

- buscar e consultar projetos e issues;
- criar e atualizar issues, comentários e status;
- registrar horas;
- acessar o restante da API.

Não há servidor separado. As chamadas rodam dentro do Redmine, com as permissões de quem está conectado.

## Requisitos

- Redmine 6.1 ou superior, que tem o provedor OAuth2 nativo. Testado nas versões 6.1 e 7.0.
- API REST ativada em *Administração → Configurações → API*.
- Redmine na raiz do domínio (ex.: `https://redmine.exemplo.com`). Os clientes MCP procuram os metadados OAuth em
  `/.well-known/...` na raiz do host.

## Instalação

```bash
cd /caminho/do/redmine/plugins
git clone https://github.com/gabera/mcp_redmine.git
# reinicie o Redmine
```

O diretório precisa se chamar `mcp_redmine`. O plugin não tem migrations nem gems extras.

Para atualizar, rode `git pull` no diretório do plugin e reinicie o Redmine.

Depois, em *Administração → Plugins → MCP Redmine → Configurar*, ajuste:

| Opção | Descrição |
|---|---|
| Ativar endpoint MCP | Liga `/mcp`, os metadados OAuth e o registro de clientes. Começa desligado |
| Formato das respostas | `yaml` (padrão) ou `json` |
| Instruções para o modelo | Orientações como "use Textile", ids de projetos e campos obrigatórios. Vão no `instructions` do servidor MCP, que os clientes colocam no prompt de sistema, e na descrição das tools `redmine_request` e `redmine_write` |

As instruções orientam o modelo, mas não o obrigam. Não as use para regras que precisam ser garantidas, como
confirmar antes de alterar dados: para isso, use as permissões do cliente (veja [Tools](#tools)).

Mudanças nas instruções valem sem reiniciar o Redmine nem desconectar ninguém:
- O `instructions` do servidor é lido na conexão, então vale nas sessões novas.
- Nas sessões abertas, a descrição das tools é atualizada: o cliente recebe `notifications/tools/list_changed`
  junto com a resposta da próxima chamada.
- O Claude Desktop ignora esse aviso e só pega o texto novo ao reconectar.

## Conectar os clientes

Em todos os clientes basta informar a URL `https://<seu-redmine>/mcp`. Na primeira conexão, o navegador abre o login
do Redmine e a tela de autorização do aplicativo.

- **Claude Code:**
  ```bash
  claude mcp add --transport http redmine https://<seu-redmine>/mcp
  ```
  Depois rode `/mcp`, escolha `redmine` e clique em *Authenticate*.
- **Claude Desktop / claude.ai:** *Configurações → Conectores → Adicionar conector personalizado*, com a URL.
- **GitHub Copilot (VS Code):** rode *MCP: Open User Configuration* e adicione
  `{ "servers": { "redmine": { "type": "http", "url": "https://<seu-redmine>/mcp" } } }`.
- **Sem OAuth:** também é possível enviar a chave de API pessoal no cabeçalho `X-Redmine-API-Key`.

## Como funciona a autenticação

O plugin usa o OAuth2 do próprio Redmine (Doorkeeper) e acrescenta o que os clientes MCP precisam:

1. O cliente chama `/mcp` e recebe `401` com o endereço de `/.well-known/oauth-protected-resource`.
2. Em `/.well-known/oauth-authorization-server`, o cliente encontra `/oauth/authorize`, `/oauth/token` e
   `/mcp/register`.
3. O cliente se registra sozinho (registro dinâmico, cliente público com PKCE). O aplicativo aparece em
   *Administração → Aplicativos* como `MCP: <nome do cliente> (<host de retorno>)`, ex.: `MCP: Claude Code (localhost)`.
4. A pessoa entra no Redmine e autoriza o aplicativo. O token vale 2 horas e é renovado com o refresh token.
   A pessoa pode revogar o acesso em *Minha conta → Aplicativos autorizados*.

O token recebe todas as permissões do Redmine como escopo. Mesmo assim, o efeito final nunca passa do que o usuário
pode fazer: o Redmine aplica as permissões dos papéis de cada um em cada chamada.

**Segurança.** Qualquer um pode registrar um cliente, como o MCP exige. Assim, um link malicioso pode pedir que
alguém autorize um aplicativo que manda o token para outro lugar. Duas coisas limitam isso:
- A tela de autorização mostra, no nome do aplicativo, o host para onde o token vai. Só autorize aplicativos cujo
  host você reconhece (`localhost`, `claude.ai` etc.).
- Tokens OAuth nunca recebem o escopo `admin`. Assim, um administrador que autoriza um cliente não entrega direitos
  de administrador. Chamadas exclusivas de admin (criar usuários, grupos, papéis etc.) não funcionam via OAuth: para
  elas, use o cabeçalho `X-Redmine-API-Key`.

Administradores podem revisar e apagar os aplicativos registrados em *Administração → Aplicativos*.

## Tools

- **`redmine_request`**: lê da API do Redmine (GET). Marcada como somente leitura.
  - Parâmetros: `path` (ex.: `/issues.json`) e `params` (query string).
- **`redmine_write`**: cria, altera ou apaga na API do Redmine. Marcada como alteração.
  - Parâmetros: `path` (ex.: `/issues/123.json`), `method` (`post`, `put`, `patch` ou `delete`), `data` (corpo)
    e `params` (query string).
- **`redmine_download`**: obtém um anexo. Marcada como somente leitura.
  - Parâmetro: `attachment_id`.
  - Retorna nome, tipo, tamanho, descrição e o link do anexo no Redmine, para a pessoa baixar no navegador (com
    login).
  - Arquivos de texto de até 1 MB vêm também com o conteúdo, e imagens de até 5 MB vêm como imagem, para o assistente
    ler. Outros tipos (PDF, zip etc.) vêm só com os dados e o link.
- **`redmine_upload`**: envia um arquivo e devolve o `token` para anexá-lo. Marcada como alteração.
  - Parâmetros: `filename`, `file_content`, `encoding` (`text`, o padrão, ou `base64`), `content_type` e
    `description`.
  - Valem os limites do Redmine: tamanho máximo e extensões permitidas.
- **`redmine_paths_list`**: lista os caminhos da especificação OpenAPI do Redmine.
- **`redmine_paths_info`**: retorna a especificação completa dos caminhos informados (ex.: `["/issues.json"]`).

`redmine_request` e `redmine_write` retornam `status_code`, `body` e `error`, e só aceitam caminhos da API
terminados em `.json`.

**Anexar arquivos.** O envio tem dois passos, como na API do Redmine:
1. `redmine_upload` envia o conteúdo e devolve um `token`.
2. `redmine_write` anexa o arquivo com `uploads`, por exemplo `PUT /issues/123.json` com
   `{"issue": {"uploads": [{"token": "...", "filename": "relatorio.md"}]}}`. O mesmo `uploads` vale para páginas
   da wiki, arquivos do projeto, documentos etc.

Arquivos enviados e nunca anexados ficam no Redmine até a task de limpeza dele removê-los (sem vínculo há mais de
um dia). O Redmine não agenda essa task, então crie um cron diário:
`bundle exec rake redmine:attachments:prune RAILS_ENV=production`.

O conteúdo vai dentro da chamada da tool, então o assistente só consegue enviar o que ele mesmo gera ou consegue
reescrever: texto, markdown, csv, código. Arquivos binários do computador da pessoa (PDF, prints, zip) devem ser
anexados pela tela do Redmine, porque o plugin roda no Redmine e não acessa o disco de quem usa.

**Confirmação antes de alterar dados.** Leitura e escrita são tools separadas para que o cliente peça aprovação
antes de toda escrita. No Claude Desktop e no claude.ai:
1. Abra *Configurações → Conectores* e escolha o Redmine.
2. Deixe as tools de leitura em *Sempre permitir* e `redmine_write` em *Sempre perguntar*.

Cada escrita passa a mostrar a chamada, com os dados, para a pessoa aprovar. Isso vale mesmo que o modelo não siga
as instruções.

Exemplos de pedidos ao assistente:

- "Liste as issues abertas de prioridade alta do projeto X sem responsável."
- "Mude a issue #123 para *Em andamento* e comente: 'Iniciado, previsão sexta-feira'."
- "Registre 3,5 horas na issue #456 hoje, atividade 'Desenvolvimento'."

## Desenvolvimento local

O `docker-compose.yml` sobe um Redmine 6.1.5 com PostgreSQL e este repositório montado como plugin:

```bash
docker compose up -d   # http://localhost:3000, login admin/admin
```

1. Ative a API REST e o plugin.
2. Conecte o cliente em `http://localhost:3000/mcp`. URLs de redirecionamento `http://localhost` são aceitas.
3. O container roda em modo produção e não recarrega código: depois de editar o plugin, rode
   `docker compose restart redmine`.

## Licença e créditos

Distribuído sob a [Apache License 2.0](LICENSE).

Baseado no [mcp-redmine](https://github.com/runekaagaard/mcp-redmine) de Rune Kaagaard, um servidor MCP em
Python. A especificação OpenAPI em `config/redmine-openapi.yml` vem de
[d-yoshi/redmine-openapi](https://github.com/d-yoshi/redmine-openapi) (MIT), com descrições revisadas para modelos
de linguagem.
