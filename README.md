# PontoMax

Controle de ponto eletrônico **REP-P (Portaria MTP 671/2021)** multiplataforma — celular (Android/iOS), web, desktop (Windows/macOS/Linux) e tablet em modo quiosque — com cálculo automático de jornada conforme a CLT.

> Inspirado no Flit (Alterdata), com todas as suas funcionalidades principais e extras (QR Code dinâmico, regime híbrido de banco de horas, assinatura eletrônica do espelho, multiempresa e API aberta).

## Funcionalidades

| Área | Recursos |
|---|---|
| **Marcação** | App (celular/desktop/web) com relógio sincronizado com o servidor · GPS com perímetro (geocerca) e detecção de GPS falso · selfie · QR Code dinâmico (muda a cada 30 s) · modo **quiosque** (tablet) com PIN, crachá ou QR pessoal · **off-line** com sincronização idempotente · anti-duplicidade · comprovante digital (tela e PDF) |
| **Cálculo (CLT)** | Tolerância 5/10 min (art. 58 §1º, Súmula 366) · horas extras 50%/100% · faltas e atrasos · adicional noturno com hora reduzida 52m30s e prorrogação (Súmula 60) · interjornada (art. 66) · intrajornada (art. 71) · limite de 2h extras (art. 59) · feriados · abonos, atestados, férias, afastamentos e folgas |
| **Escalas** | Semanal, cíclica (12x36, 6x1...), noturna (vira a meia-noite), flexível, intervalo pré-assinalado; regimes **horas extras**, **banco de horas** e **híbrido** |
| **Colaborador** | Bater ponto · espelho de ponto · solicitações (esquecimento, ajuste, atestado com foto, abono, folga, férias) · banco de horas · comprovantes · **work chat** · bloco de notas · notificações · lembretes de marcação · assinatura eletrônica do espelho · crachá digital |
| **Gestor** | Painel do dia (trabalhando, ausentes, atrasos, fora do perímetro) · mapa das marcações · colaboradores · aprovações · tratamento do ponto (incluir/desconsiderar com justificativa) · banco de horas manual · escalas · feriados (importação nacional) · perímetros no mapa · quiosques · departamentos e cargos · regras da empresa · auditoria |
| **Relatórios** | Espelho de ponto em PDF · resumo do período (CSV) · integração com folha (CSV com eventos HE50/HE100/ADN/faltas) · marcações detalhadas · **AFD** (leiaute 003, NSR, CRC-16, SHA-256 encadeado) · **AEJ** |
| **Plataforma** | Multiempresa · perfis (proprietário, administrador, gestor, colaborador) · JWT com refresh rotativo · LGPD · trilha de auditoria |

## Arquitetura

```
packages/pontomax_core   Dart puro: motor de jornada CLT, AFD/AEJ, comprovante,
                         validadores (CPF/CNPJ alfanumérico), geocerca, QR dinâmico,
                         entidades da API. Compartilhado por backend e app.
backend/                 API REST em Dart (shelf + PostgreSQL). Serve também o app
                         web (/app) e o site (/).
app/                     App Flutter (Android, iOS, Web, Windows, macOS, Linux).
site/                    Site institucional estático (landing, privacidade, termos).
docs/                    Documentação (API, conformidade, deploy, roadmap).
```

Uma única linguagem (Dart) em todo o stack: as regras de cálculo são as mesmas no servidor e no app.

## Rodando com Docker (recomendado)

```bash
cp .env.example .env               # defina JWT_SECRET (openssl rand -hex 32)
echo "SEED_DEMO=true" >> .env      # opcional: empresa de demonstração
docker compose up -d --build
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

- `packages/pontomax_core`: 52 testes do motor CLT, AFD/AEJ, validadores, geocerca e QR.
- `backend`: 17 testes de integração ponta a ponta (PostgreSQL real): autenticação, REP-P (NSR/hash/AFD), perímetro, foto, off-line, tratamento, espelho, banco de horas, solicitações, quiosque/QR, chat e dados de demonstração.
- `app`: análise estática + testes de unidade; o CI gera o build web e o APK.

## Documentação

- [API REST](docs/api.md)
- [Conformidade com a Portaria 671 e CLT](docs/conformidade.md)
- [Deploy em produção (Docker, Google Cloud Run)](docs/deploy.md)
- [Roadmap de melhorias](docs/roadmap.md)

## Licença

Proprietário — © PontoMax. Fonte Noto Sans sob SIL Open Font License 1.1.
