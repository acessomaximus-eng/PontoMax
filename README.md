# PontoMax

Controle de ponto eletrônico **REP-P (Portaria MTP 671/2021)** multiplataforma — celular (Android/iOS), web, desktop (Windows/macOS/Linux) e tablet em modo quiosque — com cálculo automático de jornada conforme a CLT.

> Inspirado no Flit (Alterdata), com todas as suas funcionalidades principais e extras (QR Code dinâmico, regime híbrido de banco de horas, assinatura eletrônica do espelho, multiempresa e API aberta).

## Funcionalidades

| Área | Recursos |
|---|---|
| **Marcação** | App (celular/desktop/web) com relógio sincronizado com o servidor · GPS com perímetro (geocerca) e detecção de GPS falso · selfie · QR Code dinâmico (muda a cada 30 s) · modo **quiosque** (tablet) com PIN, crachá ou QR pessoal · **off-line** (app e quiosque) com sincronização idempotente · anti-duplicidade · comprovante digital (tela e PDF) |
| **Cálculo (CLT)** | Tolerância 5/10 min (art. 58 §1º, Súmula 366) · horas extras 50%/100% · faltas e atrasos · adicional noturno com hora reduzida 52m30s e prorrogação (Súmula 60) · interjornada (art. 66) · intrajornada (art. 71) · limite de 2h extras (art. 59) · feriados · abonos, atestados, férias, afastamentos e folgas |
| **Escalas** | Semanal, cíclica (12x36, 6x1...), noturna (vira a meia-noite), flexível, intervalo pré-assinalado; regimes **horas extras**, **banco de horas** e **híbrido**; **faixas progressivas de hora extra** (ex.: 2h a 50%, demais a 100%) |
| **Colaborador** | Bater ponto · espelho de ponto · solicitações (esquecimento, ajuste, atestado com foto, abono, folga, férias) · banco de horas · comprovantes · **work chat** · bloco de notas · notificações · lembretes de marcação · assinatura eletrônica do espelho · crachá digital |
| **Gestor** | Painel do dia (trabalhando, ausentes, atrasos, fora do perímetro) com checklist de primeiros passos · mapa das marcações · colaboradores (cadastro ou **importação por planilha CSV**) · aprovações · tratamento do ponto (incluir/desconsiderar com justificativa) · **fechamento de período** · banco de horas manual · escalas · feriados (importação nacional) · perímetros no mapa · quiosques · departamentos e cargos · regras da empresa · auditoria · **gestor com visão só da própria equipe** (opcional) |
| **Relatórios** | Espelho de ponto em PDF · resumo do período (CSV) · integração com folha (CSV com eventos HE50/HE100/ADN/faltas) · marcações detalhadas · **AFD** (leiaute 003, NSR, CRC-16, SHA-256 encadeado) · **AEJ** · **assinatura digital** CAdES (.p7s) no AFD/AEJ e PAdES no comprovante, com certificado A1 ICP-Brasil |
| **Integração** | **API com chaves somente leitura** (folha, ERP, BI) e **webhooks assinados (HMAC)** para marcações, solicitações, colaboradores e fechamentos |
| **Plataforma** | Multiempresa · perfis (proprietário, administrador, gestor, colaborador) · JWT com refresh rotativo · limite de tentativas (login, PIN do quiosque, cadastro) · LGPD · trilha de auditoria |

## Arquitetura

```
packages/pontomax_core   Dart puro: motor de jornada CLT, AFD/AEJ, comprovante,
                         validadores (CPF/CNPJ alfanumérico), geocerca, QR dinâmico,
                         entidades da API. Compartilhado por backend e app.
backend/                 API REST em Dart (shelf + PostgreSQL). Serve também o app
                         web (/app) e o site (/).
app/                     App Flutter (Android, iOS, Web, Windows, macOS, Linux).
site/                    Site institucional estático (landing, privacidade, termos).
expo-go/                 Abre o PontoMax no Expo Go (QR Code do `npx expo start`).
docs/                    Documentação (API, conformidade, deploy, roadmap).
```

Uma única linguagem (Dart) em todo o stack: as regras de cálculo são as mesmas no servidor e no app.

## Rodando com Docker (recomendado)

> Passo a passo completo para iniciantes (computador e celular): **[docs/como-rodar.md](docs/como-rodar.md)**.

```bash
echo "SEED_DEMO=true" > .env       # opcional: empresa de demonstração
docker compose up -d --build       # JWT_SECRET é gerado se não for definido
```

- Site: http://localhost:8080
- App web: http://localhost:8080/app
- API: http://localhost:8080/api/v1/health

Demonstração (`SEED_DEMO=true`): `admin@pontomax.app` / `pontomax123` (proprietário) e `ana@pontomax.app` / `pontomax123` (colaboradora). Quiosque: código de ativação `DEMO2026`, PIN `1234` (matrículas 001–007).

## Desenvolvimento

Requisitos: Dart 3.13+/Flutter 3.47+ e PostgreSQL 16.

```bash
# Banco local
createuser -s pontomax && createdb -O pontomax pontomax && createdb -O pontomax pontomax_test

# Núcleo
cd packages/pontomax_core && dart pub get && dart test

# API (porta 8080, com dados de demonstração)
cd backend && dart pub get && SEED_DEMO=true dart run bin/server.dart
dart test -j 1     # testes de integração (usa o banco pontomax_test)

# App
cd app && flutter pub get
flutter run -d chrome                         # web (API em localhost:8080)
flutter run -d android --dart-define=API_URL=http://10.0.2.2:8080
flutter build web --base-href /app/ --no-web-resources-cdn   # servido pela API via WEB_DIR
```

Variáveis da API: veja [`.env.example`](.env.example) e [`backend/lib/src/config.dart`](backend/lib/src/config.dart).

## Testes

- `packages/pontomax_core`: 64 testes do motor CLT (inclusive faixas de hora extra e validade do banco), AFD/AEJ, validadores, geocerca e QR.
- `backend`: 27 testes de integração ponta a ponta (PostgreSQL real): autenticação, REP-P (NSR/hash/AFD), perímetro, foto, off-line, tratamento, espelho, banco de horas, solicitações, quiosque/QR, limite de PIN, fechamento de período, visão por equipe, importação CSV, chaves de API, webhooks, chat, dados de demonstração, equivalência da apuração em lote e assinaturas CAdES/PAdES (com certificados .pfx atual e legado validados pelo OpenSSL).
- `e2e`: Playwright no app web (login do gestor, marcação com GPS, quiosque com PIN); `CPU_THROTTLE=6` simula máquinas lentas.
- `app`: análise estática + testes de unidade/widget; o CI gera o build web, o **APK Android** e a imagem Docker.

## Documentação

- [Como rodar (passo a passo)](docs/como-rodar.md)
- [API REST](docs/api.md)
- [Conformidade com a Portaria 671 e CLT](docs/conformidade.md)
- [Deploy em produção (Docker, Google Cloud Run)](docs/deploy.md)
- [Roadmap de melhorias](docs/roadmap.md)

## Licença

Proprietário — © PontoMax. Fonte Noto Sans sob SIL Open Font License 1.1.
