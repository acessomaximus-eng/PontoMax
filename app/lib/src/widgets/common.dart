import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../theme.dart';

// ---------------------------------------------------------------------------
// Formatação
// ---------------------------------------------------------------------------

String hm(int minutes, {bool signed = false, bool dashIfZero = false}) =>
    dashIfZero && minutes == 0 ? '—' : TimeFmt.minutes(minutes, signed: signed);

String dateBr(LocalDate d) => d.toBr();

String dateLong(LocalDate d) =>
    DateFormat("EEEE, d 'de' MMMM", 'pt_BR').format(d.toDateTime());

String monthLabel(LocalDate d) =>
    DateFormat("MMMM 'de' y", 'pt_BR').format(d.toDateTime());

String relativeTime(DateTime utc) {
  final diff = DateTime.now().toUtc().difference(utc);
  if (diff.inMinutes < 1) return 'agora';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'há ${diff.inHours} h';
  if (diff.inDays < 7) return 'há ${diff.inDays} d';
  return DateFormat('dd/MM/yyyy', 'pt_BR').format(utc.toLocal());
}

String capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

// ---------------------------------------------------------------------------
// Feedback
// ---------------------------------------------------------------------------

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.danger : null,
      ),
    );
}

String errorMessage(Object e) => e is ApiException ? e.message : e.toString();

/// Executa uma ação com feedback de erro/sucesso.
Future<T?> runAction<T>(
  BuildContext context,
  Future<T> Function() action, {
  String? success,
}) async {
  try {
    final r = await action();
    if (success != null && context.mounted) showSnack(context, success);
    return r;
  } catch (e) {
    if (context.mounted) showSnack(context, errorMessage(e), error: true);
    return null;
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String ok = 'Confirmar',
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(
  BuildContext context,
  String title, {
  String label = '',
  String initial = '',
  bool required = true,
  int maxLines = 1,
}) async {
  final ctrl = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            if (required && ctrl.text.trim().isEmpty) return;
            Navigator.pop(c, ctrl.text.trim());
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return r;
}

// ---------------------------------------------------------------------------
// Estados assíncronos
// ---------------------------------------------------------------------------

class AsyncView<T> extends StatelessWidget {
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final bool sliver;

  const AsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
    this.sliver = false,
  });

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: builder,
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (e, _) => ErrorView(message: errorMessage(e), onRetry: onRetry),
    );
  }
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorView({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 48, color: AppColors.muted),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ],
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: t.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 36,
                color: t.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                style: t.textTheme.bodyMedium?.copyWith(color: AppColors.muted),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Componentes visuais
// ---------------------------------------------------------------------------

class SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionTitle(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.2),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? hint;
  final VoidCallback? onTap;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.color = AppColors.brand,
    this.hint,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      style: t.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      label,
                      style: t.textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (hint != null)
                      Text(
                        hint!,
                        style: t.textTheme.labelSmall?.copyWith(color: color),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String name;
  final String? url;
  final double radius;
  const Avatar({super.key, required this.name, this.url, this.radius = 20});

  String get initials {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFF6366F1),
      const Color(0xFF0EA5E9),
      const Color(0xFF10B981),
      const Color(0xFFF59E0B),
      const Color(0xFFEC4899),
      const Color(0xFF8B5CF6),
    ];
    final color = colors[name.hashCode.abs() % colors.length];
    final resolved = AppConfig.resolveUrl(url);
    return CircleAvatar(
      radius: radius,
      backgroundColor: color.withValues(alpha: 0.18),
      foregroundImage: resolved.isEmpty ? null : NetworkImage(resolved),
      child: Text(
        initials,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  const StatusChip(this.label, {super.key, required this.color, this.icon});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

Color dayStatusColor(DayStatus s) => switch (s) {
  DayStatus.normal => AppColors.accent,
  DayStatus.absent => AppColors.danger,
  DayStatus.incomplete => AppColors.warning,
  DayStatus.holiday || DayStatus.dayOff => AppColors.muted,
  DayStatus.excused ||
  DayStatus.vacation ||
  DayStatus.leave ||
  DayStatus.bankDayOff => AppColors.info,
  DayStatus.open => AppColors.brand,
  DayStatus.notEmployed => AppColors.muted,
};

Color requestStatusColor(RequestStatus s) => switch (s) {
  RequestStatus.pending => AppColors.warning,
  RequestStatus.approved => AppColors.accent,
  RequestStatus.rejected => AppColors.danger,
  RequestStatus.cancelled => AppColors.muted,
};

IconData requestTypeIcon(RequestType t) => switch (t) {
  RequestType.forgotPunch => Icons.more_time_rounded,
  RequestType.adjustment => Icons.edit_calendar_rounded,
  RequestType.medicalCertificate => Icons.medical_services_outlined,
  RequestType.allowance => Icons.verified_outlined,
  RequestType.bankDayOff => Icons.beach_access_outlined,
  RequestType.vacation => Icons.flight_takeoff_rounded,
};

/// Seletor de mês (‹ outubro de 2026 ›).
class MonthSelector extends StatelessWidget {
  final LocalDate month;
  final ValueChanged<LocalDate> onChanged;
  const MonthSelector({
    super.key,
    required this.month,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Mês anterior',
        onPressed: () => onChanged(month.addMonths(-1).firstDayOfMonth),
        icon: const Icon(Icons.chevron_left),
      ),
      Text(
        capitalize(monthLabel(month)),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      IconButton(
        tooltip: 'Próximo mês',
        onPressed: () => onChanged(month.addMonths(1).firstDayOfMonth),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
}

/// Limita a largura do conteúdo em telas grandes.
class Constrained extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const Constrained({super.key, required this.child, this.maxWidth = 1100});

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// Grade responsiva de cartões.
class ResponsiveGrid extends StatelessWidget {
  final List<Widget> children;
  final double minItemWidth;
  final double spacing;
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.minItemWidth = 220,
    this.spacing = 12,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // Em telas estreitas (celular), ao menos 2 colunas para cartões compactos.
      final min = c.maxWidth < 600 ? minItemWidth.clamp(0, c.maxWidth / 2 - spacing) : minItemWidth;
      final columns = (c.maxWidth / min).floor().clamp(1, 6);
      final width = (c.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [for (final w in children) SizedBox(width: width, child: w)],
      );
    },
  );
}

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 900;
