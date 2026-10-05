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
| GET | `/reports/afd` · `/reports/aej` | gestor | Arquivos da Portaria 671 |
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
