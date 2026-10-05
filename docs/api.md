# API REST do PontoMax

Base: `/api/v1`. JSON em UTF-8. Datas `AAAA-MM-DD`; instantes ISO-8601 em UTC.

## Autenticação

- `Authorization: Bearer <access_token>` (JWT, 2 h) — renove com `POST /auth/refresh` (refresh token de uso único, 30 dias).
- `X-Company-Id: <uuid>` seleciona a empresa ativa (multiempresa). Sem o cabeçalho, usa o primeiro vínculo.
- Quiosques usam `Authorization: Device <device_token>` (obtido em `POST /kiosk/activate`).
- Erros: `{"error": {"code": "...", "message": "..."}}` com status HTTP adequado (400, 401, 403, 404, 409, 422, 429).

## Endpoints

| Método | Rota | Perfil | Descrição |
|---|---|---|---|
| GET | `/health` | público | Saúde da API e do banco |
| GET | `/time` | público | Hora oficial do servidor (sincronização do relógio) |
| POST | `/auth/register` | público | Cria empresa + proprietário (escala padrão e feriados nacionais) |
| POST | `/auth/login` · `/auth/refresh` · `/auth/logout` | público | Sessão |
| POST | `/auth/forgot` · `/auth/reset` | público | Recuperação de senha por e-mail |
| GET/PUT | `/me` | todos | Usuário, vínculos, empresa e contadores |
| PUT | `/me/password` · `/me/pin` | todos | Senha e PIN do quiosque |
| GET/PUT | `/company` · PUT `/company/settings` | admin | Dados do empregador e regras |
| POST | `/companies` | todos | Nova empresa para o mesmo usuário |
| CRUD | `/departments` · `/positions` | gestor | Departamentos e cargos |
| CRUD | `/holidays` · POST `/holidays/import-national` | gestor | Feriados |
| CRUD | `/geofences` | gestor | Perímetros |
| CRUD | `/schedules` | gestor | Escalas (definição JSON do núcleo) |
| CRUD | `/devices` · POST `/devices/{id}/activation` | gestor | Quiosques |
| GET/POST/PUT | `/members` · `/members/{id}` | gestor | Colaboradores (CPF obrigatório) |
| POST | `/members/{id}/dismiss` · `/reactivate` · `/reset-password` · PUT `/pin` | gestor | Ciclo de vida |
| POST | `/punches` | todos | Registrar marcação (GPS, foto, QR, off-line) → marcação + comprovante |
| POST | `/punches/sync` | todos | Envio em lote de marcações off-line (idempotente por `client_id`) |
| GET | `/punches` · `/punches/today` · `/punches/{id}` | todos | Consulta |
| GET | `/punches/{id}/receipt` · `/receipt.pdf` | todos | Comprovante |
| POST | `/punches/manual` · `/{id}/disregard` · `/{id}/restore` · DELETE `/{id}` | gestor | Tratamento do ponto |
| GET/POST | `/requests` · POST `/{id}/approve` · `/reject` · `/cancel` | todos/gestor | Solicitações |
| GET/POST/DELETE | `/absences` | gestor | Abonos, atestados, férias, afastamentos |
| GET | `/bank` · POST/DELETE `/bank/entries` | todos/gestor | Banco de horas |
| GET | `/timesheet` · `/timesheet.pdf` | todos | Espelho de ponto (gestor: `member_id`) |
| POST | `/timesheet/sign` · GET `/timesheet/signatures` | todos | Assinatura eletrônica |
| GET | `/reports/summary` · `.csv` · `/payroll.csv` · `/punches.csv` | gestor | Relatórios |
| GET | `/reports/afd` · `/reports/aej` | gestor | Arquivos da Portaria 671; com `signed=true`, ZIP com o `.txt` e a assinatura CAdES `.p7s` |
| GET | `/signature` | administrador | Certificado de assinatura em uso (titular, emissor, validade, ICP-Brasil, autoassinado) |
| POST | `/signature/verify` | gestor | `{content, signature}` em base64 → `{valid, signer, issuer, signing_time, error}` |
| GET | `/dashboard` · `/audit` | gestor | Painel e auditoria |
| GET/POST | `/chat/conversations` · `/chat/{memberId}/messages` · POST `/read` | todos | Work chat (long-polling com `after` + `wait`) |
| GET | `/events/wait` | todos | Long-polling de eventos |
| CRUD | `/notes` | todos | Bloco de notas |
| GET/POST | `/notifications` · `/read-all` · `/{id}/read` | todos | Notificações |
| POST/GET | `/files` · `/files/{id}` | todos | Upload (corpo binário + `X-Filename`) e download (URL assinada) |
| POST/GET | `/kiosk/activate` · `/kiosk/me` · `/kiosk/qr` · `/kiosk/members` · `/kiosk/identify` · `/kiosk/punch` · `/kiosk/upload` | quiosque | Modo quiosque |

Períodos: `from`/`to` ou `period=AAAA-MM` (respeita o dia de fechamento da empresa).

## Exemplo: registrar ponto

```http
POST /api/v1/punches
Authorization: Bearer …
Content-Type: application/json

{"source": "mobile", "lat": -23.5643, "lng": -46.6529, "accuracy": 12, "photo_file_id": "…", "client_id": "a1b2…"}
```

Resposta `201`: `{"punch": {...,"nsr": 1104, "hash": "…"}, "receipt": {"fields": [...], "text": "…"}}`.

## Integração (folha de pagamento, ERP, BI)

### Chaves de API

Crie em **Configurações › Integrações (API)** (somente administradores). A chave completa (`pmx_<prefixo>_<segredo>`) é exibida apenas uma vez; o servidor guarda só o hash SHA-256.

```bash
curl -H "X-Api-Key: pmx_abcd1234_..." \
  "https://SEU_DOMINIO/api/v1/punches?from=2026-10-01&to=2026-10-31"
```

- Somente **GET** e apenas nas rotas: `members`, `punches`, `timesheet`, `reports/*` (resumo, folha, marcações, AFD, AEJ), `holidays`, `schedules`, `departments`, `positions`, `absences`, `requests`, `bank`, `company`, `geofences`.
- A chave age com a visão de gestor da empresa; uso fica registrado em `last_used_at`; revogue a qualquer momento.

### Webhooks

Eventos: `punch.created`, `request.created`, `request.approved`, `request.rejected`, `member.created`, `member.dismissed`, `period.closed` (e `ping` no teste).

```http
POST https://seu-sistema/webhook
Content-Type: application/json
X-PontoMax-Event: punch.created
X-PontoMax-Delivery: 3f9a...
X-PontoMax-Signature: sha256=<HMAC-SHA256 do corpo com o segredo do webhook>

{"id": "3f9a...", "event": "punch.created", "created_at": "2026-10-05T11:00:00Z", "data": { ...marcação... }}
```

Responda 2xx em até 15 s. Falhas são tentadas novamente até 3 vezes; o último status aparece na tela de integrações.

Validação da assinatura (Node.js):

```js
const sig = 'sha256=' + crypto.createHmac('sha256', SEGREDO).update(rawBody).digest('hex');
if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(req.headers['x-pontomax-signature']))) throw new Error('assinatura inválida');
```
