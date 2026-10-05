/// Núcleo compartilhado do PontoMax.
///
/// * Motor de apuração de jornada (CLT) e banco de horas.
/// * Geração de AFD/AEJ e comprovante (Portaria MTP 671/2021).
/// * Validadores de CPF/CNPJ, geocerca e QR Code dinâmico.
/// * Entidades do contrato da API.
library;

export 'src/engine/calculator.dart';
export 'src/engine/holidays_br.dart';
export 'src/engine/schedule.dart';
export 'src/geo/geo.dart';
export 'src/legal/aej.dart';
export 'src/legal/afd.dart';
export 'src/legal/receipt.dart';
export 'src/models/entities.dart';
export 'src/models/enums.dart';
export 'src/security/qr_token.dart';
export 'src/time/local_date.dart';
export 'src/validators/documents.dart';
