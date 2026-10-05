# Roadmap de melhorias contínuas

## Concluído (v0.1)
- Núcleo CLT, AFD/AEJ, comprovante, validadores, geocerca, QR dinâmico (52 testes).
- API completa com PostgreSQL (17 testes de integração).
- App Flutter multiplataforma: colaborador, gestor e quiosque; build web servido pela API.
- Site institucional, Docker, CI e release multiplataforma.

## Concluído (v0.2)
- Fechamento de período com bloqueio do tratamento e reabertura auditada.
- API de integração (chaves somente leitura) e webhooks assinados.
- Faixas progressivas de hora extra (convenções coletivas).
- Quiosque off-line com fila local.
- Gestor com visão restrita à própria equipe.
- Importação de colaboradores por CSV e checklist de primeiros passos.
- Proteções: limite de PIN no quiosque e de cadastros por IP.

## Próximas iterações
1. **Reconhecimento facial**: comparar a selfie com a foto de referência (ML Kit no app + verificação no servidor) e liveness.
2. **Assinatura CAdES do AFD/AEJ** com certificado ICP-Brasil (arquivo `.p7s`).
3. **Push notifications** (FCM/APNs) para aprovações, mensagens e lembretes remotos.
4. **Tempo real escalável**: `LISTEN/NOTIFY` do PostgreSQL ou Redis no lugar do `EventBus` em memória; WebSocket.
5. **Armazenamento em nuvem** (S3/GCS) para fotos e anexos, com retenção configurável.
6. **Snapshot do banco de horas** no fechamento e compensação/expiração de saldo (ex.: 6 meses).
7. **Permissões granulares** por gestor (aprovar, tratar, exportar).
8. **Layouts de exportação** para folhas populares (Domínio, Alterdata, Senior, TOTVS) e eSocial (S-1010/S-2230).
9. **Escalas avançadas**: troca de turno, escala mensal desenhada, DSR e feriados estaduais/municipais automáticos por município.
10. **Relatórios extras**: absenteísmo, horas por departamento, gráficos de tendência, envio agendado por e-mail.
11. **Ponto por comando de voz** e atalhos (widgets Android/iOS, Apple Watch/Wear OS).
13. **Testes E2E** automatizados (Playwright no app web) e testes de widgets.
14. **Internacionalização** e acessibilidade (leitor de tela, contraste).
