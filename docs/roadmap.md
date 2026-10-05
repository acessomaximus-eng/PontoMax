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

## Concluído (v0.3)
- Validade do banco de horas (art. 59 §5º) com compensação FIFO.
- Assinatura digital: CAdES destacada no AFD/AEJ e PAdES no comprovante, com certificado A1 (.pfx) ou autoassinado.
- Relatórios da empresa até 6x mais rápidos (apuração em lote; teste com 200 colaboradores e 200 mil marcações).
- Testes E2E com Playwright no CI.

## Próximas iterações
1. **Reconhecimento facial**: comparar a selfie com a foto de referência (ML Kit no app + verificação no servidor) e liveness.
2. **Política de assinatura ICP-Brasil (AD-RB)** e carimbo do tempo nas assinaturas; validação da cadeia e LCR.
3. **Push notifications** (FCM/APNs) para aprovações, mensagens e lembretes remotos.
4. **Tempo real escalável**: `LISTEN/NOTIFY` do PostgreSQL ou Redis no lugar do `EventBus` em memória; WebSocket.
5. **Armazenamento em nuvem** (S3/GCS) para fotos e anexos, com retenção configurável.
6. **Snapshot do banco de horas** no fechamento (congela o saldo dos períodos fechados).
7. **Permissões granulares** por gestor (aprovar, tratar, exportar).
8. **Layouts de exportação** para folhas populares (Domínio, Alterdata, Senior, TOTVS) e eSocial (S-1010/S-2230).
9. **Escalas avançadas**: troca de turno, escala mensal desenhada, DSR e feriados estaduais/municipais automáticos por município.
10. **Relatórios extras**: absenteísmo, horas por departamento, gráficos de tendência, envio agendado por e-mail.
11. **Ponto por comando de voz** e atalhos (widgets Android/iOS, Apple Watch/Wear OS).
13. **Mais cenários E2E** (aprovações, tratamento, relatórios) e testes de widgets.
14. **Internacionalização** e acessibilidade (leitor de tela, contraste).
