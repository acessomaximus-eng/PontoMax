# Conformidade legal

## Portaria MTP nº 671/2021 — REP-P

| Requisito | Implementação |
|---|---|
| Identificação do empregador e do trabalhador (CPF) | Cadastro da empresa (CNPJ/CPF, CNO/CAEPF, endereço) e CPF obrigatório do colaborador |
| Relógio sincronizado com a hora legal (±30 s) e exibição com segundos | O horário da marcação é sempre o do servidor (sincronizado via NTP). O app exibe o relógio do servidor (`/time`) com segundos |
| NSR sequencial | Sequência por empresa, atribuída em transação com bloqueio da linha da empresa |
| Marcações off-line | Permitidas (configurável), enviadas depois e marcadas como off-line no AFD (campo 7 do registro tipo 7) |
| AFD leiaute 003 | Registros 1 (cabeçalho), 2 (empregador), 5 (empregado), 7 (marcação REP-P com SHA-256 encadeado), 9 (trailer); CRC-16/KERMIT; ISO-8859-1; CRLF |
| AEJ | Registros 01–08 e 99 (vínculos, horário contratual, marcações tratadas com fonte O/I/P, ausências e banco de horas) |
| Comprovante de registro | Exibido após cada marcação e disponível em PDF, com NSR e hash |
| Inalterabilidade | Marcações originais não podem ser editadas nem excluídas; tratamento por inclusão (fonte `I`) e desconsideração justificadas, com auditoria |
| Número de registro no INPI | Configurável (`REP_INPI_NUMBER` ou nas regras da empresa) |
| Assinatura do AFD (CAdES) | **Pendente** — requer certificado ICP-Brasil do desenvolvedor (ver roadmap) |

> Pontos a validar antes da homologação: confira os leiautes com a versão vigente dos Anexos V e VI da Portaria 671 e registre o programa no INPI.

## CLT

| Regra | Onde |
|---|---|
| Tolerância de 5 min por marcação e 10 min diários (art. 58 §1º; Súmula 366 TST) | `JourneyCalculator` — se ultrapassada, todo o tempo é computado |
| Horas extras e limite de 2h diárias (art. 59) | Percentuais configuráveis por escala; inconsistência apontada acima de 2h |
| Interjornada de 11h (art. 66) | Inconsistência com os minutos faltantes |
| Intervalo intrajornada (art. 71) | 1h para jornadas > 6h; 15 min para 4–6h |
| Hora noturna reduzida (art. 73) | 22h–5h com hora de 52m30s; prorrogação conforme Súmula 60 |
| Banco de horas (art. 59 §2º/§5º) | Regimes banco de horas e híbrido; lançamentos manuais e saldo inicial |

## LGPD

Localização coletada somente no momento da marcação; URLs de arquivos assinadas e temporárias; senhas e PINs com PBKDF2; perfis de acesso; auditoria de alterações; política de privacidade em `/privacidade.html`.
