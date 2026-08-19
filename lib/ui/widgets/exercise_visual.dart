import 'package:flutter/material.dart';

/// Original, deliberately schematic movement guides. The caller must supply
/// an explicit visual ID from the resolved plan; this widget never guesses
/// from an exercise name.
class ExerciseVisualCard extends StatelessWidget {
  final String visualId;
  final String exerciseName;

  const ExerciseVisualCard({
    super.key,
    required this.visualId,
    required this.exerciseName,
  });

  @override
  Widget build(BuildContext context) {
    final hold = visualId == 'backExtensionHold' || visualId == 'plank';
    return Semantics(
      label: 'Movement guide for $exerciseName',
      image: true,
      child: Card(
        key: ValueKey('exercise-visual-$visualId'),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Column(
            children: [
              SizedBox(
                height: 94,
                child: Row(
                  children: [
                    Expanded(
                      child: CustomPaint(
                        painter: _ExercisePosePainter(
                          visualId: visualId,
                          finish: false,
                          colorScheme: Theme.of(context).colorScheme,
                        ),
                      ),
                    ),
                    if (!hold) ...[
                      Icon(
                        Icons.arrow_forward,
                        size: 18,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      Expanded(
                        child: CustomPaint(
                          painter: _ExercisePosePainter(
                            visualId: visualId,
                            finish: true,
                            colorScheme: Theme.of(context).colorScheme,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                hold ? 'Controlled hold' : 'Start  →  finish',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExercisePosePainter extends CustomPainter {
  final String visualId;
  final bool finish;
  final ColorScheme colorScheme;

  const _ExercisePosePainter({
    required this.visualId,
    required this.finish,
    required this.colorScheme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = colorScheme.onSurface
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final accent = Paint()
      ..color = colorScheme.primary
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final equipment = Paint()
      ..color = colorScheme.outline
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    Offset p(double x, double y) => Offset(size.width * x, size.height * y);
    void line(Offset a, Offset b, [Paint? paint]) =>
        canvas.drawLine(a, b, paint ?? ink);
    void head(Offset at) => canvas.drawCircle(at, size.height * 0.07, ink);

    switch (visualId) {
      case 'pullUp':
        line(p(.18, .08), p(.82, .08), equipment);
        final shoulderY = finish ? .30 : .46;
        head(p(.5, shoulderY - .12));
        line(p(.5, shoulderY), p(.5, .68), ink);
        line(p(.5, shoulderY + .05), p(.36, finish ? .22 : .08), accent);
        line(p(.36, finish ? .22 : .08), p(.24, .08), accent);
        line(p(.5, shoulderY + .05), p(.64, finish ? .22 : .08), accent);
        line(p(.64, finish ? .22 : .08), p(.76, .08), accent);
        line(p(.5, .68), p(.38, .92));
        line(p(.5, .68), p(.62, .92));
        break;
      case 'pushUp' || 'plank':
        final hipY = finish && visualId == 'pushUp' ? .58 : .43;
        head(p(.18, .38));
        line(p(.25, .43), p(.64, hipY), accent);
        line(p(.64, hipY), p(.86, .76));
        line(p(.34, .46), p(finish ? .31 : .46, finish ? .76 : .72));
        line(p(finish ? .31 : .46, finish ? .76 : .72), p(.2, .76));
        line(p(.1, .78), p(.9, .78), equipment);
        break;
      case 'floorPress' || 'bridgeCurl':
        line(p(.08, .78), p(.92, .78), equipment);
        head(p(.18, .67));
        final hip = visualId == 'bridgeCurl' ? (finish ? .42 : .67) : .67;
        line(p(.27, .68), p(.62, hip), accent);
        line(p(.62, hip), p(.82, .72));
        if (visualId == 'floorPress') {
          final handY = finish ? .16 : .48;
          line(p(.38, .63), p(.38, handY), accent);
          line(p(.62, .63), p(.62, handY), accent);
          canvas.drawCircle(p(.38, handY), 4, equipment);
          canvas.drawCircle(p(.62, handY), 4, equipment);
        } else {
          line(p(.82, .72), p(finish ? .65 : .9, .78), accent);
        }
        break;
      case 'backExtensionHold' || 'backExtensionDynamic' || 'chestSupportedRow':
        line(p(.12, .66), p(.62, .66), equipment);
        line(p(.2, .66), p(.2, .9), equipment);
        line(p(.55, .66), p(.55, .9), equipment);
        final shoulderY = visualId == 'backExtensionDynamic' && !finish ? .68 : .43;
        head(p(.83, shoulderY - .06));
        line(p(.55, .55), p(.76, shoulderY), accent);
        line(p(.55, .55), p(.30, .48));
        if (visualId == 'chestSupportedRow') {
          final handY = finish ? .48 : .78;
          line(p(.62, .52), p(.70, handY), accent);
          canvas.drawCircle(p(.70, handY), 4, equipment);
        } else {
          line(p(.67, shoulderY), p(.76, shoulderY + .14));
        }
        break;
      case 'gobletSquat' || 'splitSquat':
        final hipY = finish ? .58 : .42;
        head(p(.5, .18));
        line(p(.5, .27), p(.5, hipY), accent);
        canvas.drawCircle(p(.5, .36), 5, equipment);
        if (visualId == 'splitSquat') {
          line(p(.5, hipY), p(.32, finish ? .68 : .61), accent);
          line(p(.32, finish ? .68 : .61), p(.20, .87), accent);
          line(p(.5, hipY), p(.68, .65), accent);
          line(p(.68, .65), p(.84, .87), accent);
        } else {
          line(p(.5, hipY), p(.34, finish ? .66 : .64), accent);
          line(p(.34, finish ? .66 : .64), p(.32, .88), accent);
          line(p(.5, hipY), p(.66, finish ? .66 : .64), accent);
          line(p(.66, finish ? .66 : .64), p(.68, .88), accent);
        }
        break;
      case 'seatedPress':
        line(p(.34, .42), p(.34, .82), equipment);
        line(p(.34, .72), p(.7, .72), equipment);
        head(p(.5, .22));
        line(p(.5, .3), p(.5, .62), accent);
        final handY = finish ? .08 : .37;
        line(p(.48, .35), p(.35, handY), accent);
        line(p(.52, .35), p(.65, handY), accent);
        canvas.drawCircle(p(.35, handY), 4, equipment);
        canvas.drawCircle(p(.65, handY), 4, equipment);
        break;
      case 'curl' || 'lateralRaise':
        head(p(.5, .18));
        line(p(.5, .27), p(.5, .64), accent);
        final handY = finish ? (visualId == 'curl' ? .34 : .30) : .64;
        final handX = finish && visualId == 'lateralRaise' ? .18 : .35;
        line(p(.48, .34), p(handX, handY), accent);
        line(p(.52, .34), p(1 - handX, handY), accent);
        canvas.drawCircle(p(handX, handY), 4, equipment);
        canvas.drawCircle(p(1 - handX, handY), 4, equipment);
        line(p(.5, .64), p(.38, .9));
        line(p(.5, .64), p(.62, .9));
        break;
      case 'dip':
        line(p(.16, .45), p(.38, .45), equipment);
        line(p(.62, .45), p(.84, .45), equipment);
        final shoulderY = finish ? .48 : .30;
        head(p(.5, shoulderY - .14));
        line(p(.5, shoulderY), p(.5, .67), accent);
        line(p(.5, shoulderY), p(.35, .45), accent);
        line(p(.5, shoulderY), p(.65, .45), accent);
        line(p(.5, .67), p(.4, .9));
        line(p(.5, .67), p(.6, .9));
        break;
      case 'tibialisRaise' || 'calfRaise':
        line(p(.25, .88), p(.75, .88), equipment);
        head(p(.5, .17));
        line(p(.5, .25), p(.5, .62), accent);
        line(p(.5, .62), p(.42, .84), accent);
        line(p(.5, .62), p(.58, .84), accent);
        final toeY = finish ? (visualId == 'calfRaise' ? .79 : .91) : .88;
        line(p(.42, .84), p(.30, toeY), accent);
        line(p(.58, .84), p(.70, toeY), accent);
        break;
      case 'elevatedDeadlift':
        line(p(.18, .82), p(.82, .82), equipment);
        final hipY = finish ? .47 : .62;
        head(p(finish ? .5 : .68, finish ? .18 : .32));
        line(p(.5, hipY), p(finish ? .5 : .67, finish ? .28 : .40), accent);
        line(p(.5, hipY), p(.38, .83), accent);
        line(p(.5, hipY), p(.62, .83), accent);
        line(p(.58, .44), p(.66, finish ? .64 : .72), accent);
        canvas.drawCircle(p(.66, finish ? .64 : .72), 5, equipment);
        break;
      default:
        head(p(.5, .22));
        line(p(.5, .31), p(.5, .66), accent);
        line(p(.5, .4), p(.28, .6), accent);
        line(p(.5, .4), p(.72, .6), accent);
        line(p(.5, .66), p(.38, .91), accent);
        line(p(.5, .66), p(.62, .91), accent);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _ExercisePosePainter oldDelegate) =>
      oldDelegate.visualId != visualId ||
      oldDelegate.finish != finish ||
      oldDelegate.colorScheme != colorScheme;
}
