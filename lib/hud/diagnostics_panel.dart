import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'hud_theme.dart';

/// Una fila del panel: nombre de parámetro y valor.
@immutable
class DiagnosticRow {
  const DiagnosticRow(this.label, this.value);

  final String label;
  final String value;
}

/// Panel de diagnóstico de desarrollo (AC-2.7).
///
/// No es parte del HUD: es la instrumentación con la que se miden los criterios
/// de REQ-9, y por eso vive detrás de un interruptor. Lo que el usuario ve en
/// condiciones normales es la franja inferior.
class DiagnosticsPanel extends StatelessWidget {
  const DiagnosticsPanel({
    super.key,
    required this.title,
    required this.rows,
    required this.theme,
  });

  final String title;
  final List<DiagnosticRow> rows;
  final HudTheme theme;

  @override
  Widget build(BuildContext context) {
    // Ancho de la columna de parámetros, calculado sobre el nombre más largo.
    // En monoespaciada el avance ronda 0,6 em, así que la cuenta es fiable sin
    // tener que medir cada texto.
    final longest = rows.fold<int>(0, (max, r) => math.max(max, r.label.length));
    final labelWidth = longest * theme.panelTextSize * 0.62 + theme.panelTextSize;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: theme.panelTextSize * 1.1,
        vertical: theme.panelTextSize * 0.95,
      ),
      decoration: BoxDecoration(
        color: theme.panel,
        borderRadius: BorderRadius.circular(theme.panelTextSize * 0.4),
        border: Border.all(color: theme.panelBorder, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: hudText(
              color: theme.highlight,
              size: theme.titleSize,
              letterSpacing: theme.titleSize * 0.14,
              height: 1.3,
            ),
          ),
          SizedBox(height: theme.panelTextSize * 0.55),
          for (final row in rows)
            Padding(
              padding: EdgeInsets.only(bottom: theme.panelTextSize * 0.28),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Text(
                      row.label,
                      style: hudText(
                        color: theme.structure,
                        size: theme.panelTextSize,
                        height: 1.35,
                      ),
                    ),
                  ),
                  Text(
                    row.value,
                    style: hudText(
                      color: theme.highlight,
                      size: theme.panelTextSize,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
