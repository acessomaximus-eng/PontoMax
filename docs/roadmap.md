# Roadmap de melhorias contínuas

## Concluído (v0.1)
- Núcleo CLT, AFD/AEJ, comprovante, validadores, geocerca, QR dinâmico (52 testes).
- API completa com PostgreSQL (17 testes de integração).
- App Flutter multiplataforma: colaborador, gestor e quiosque; build web servido pela API.
- Site institucional, Docker, CI e release multiplataforma.

## Próximas iterações
1. **Reconhecimento facial**: comparar a selfie com a foto de referência (ML Kit no app + verificação no servidor) e liveness.
2. **Assinatura CAdES do AFD/AEJ** com certificado ICP-Brasil (arquivo `.p7s`).
3. **Push notifications** (FCM/APNs) para aprovações, mensagens e lembretes remotos.
4. **Tempo real escalável**: `LISTEN/NOTIFY` do PostgreSQL ou Redis no lugar do `EventBus` em memória; WebSocket.
5. **Armazenamento em nuvem** (S3/GCS) para fotos e anexos, com retenção configurável.
6. **Fechamento de período**: travar o tratamento após o fechamento e gerar snapshot do banco de horas.
7. **Gestores por departamento** (escopo de visibilidade) e permissões granulares.
8. **Integrações**: layouts de exportação para folhas populares (Domínio, Alterdata, Senior, TOTVS), eSocial (S-1010/S-2230) e webhooks/API keys.
9. **Escalas avançadas**: troca de turno, escala mensal desenhada, DSR e feriados estaduais/municipais automáticos por município.
10. **Relatórios extras**: absenteísmo, horas por departamento, gráficos de tendência, envio agendado por e-mail.
11. **Ponto por comando de voz** e atalhos (widgets Android/iOS, Apple Watch/Wear OS).
12. **Offline do quiosque** com fila local e sincronização.
13. **Testes E2E** automatizados (Playwright no app web) e testes de widgets.
14. **Internacionalização** e acessibilidade (leitor de tela, contraste).
