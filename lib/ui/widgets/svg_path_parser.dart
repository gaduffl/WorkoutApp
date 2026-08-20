import 'dart:ui';

/// Parses the SVG path subset used by the bundled anatomical artwork.
///
/// The implementation follows the SVG path-data grammar and deliberately has
/// no rendering dependency. It supports every standard path command, including
/// compact numbers such as `.5-.2` and elliptical arcs.
Path parseSvgPathData(String data) {
  final tokens = RegExp(
    r'[a-zA-Z]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?',
  ).allMatches(data).map((match) => match.group(0)!).toList();
  final path = Path();
  var index = 0;
  var command = '';
  var current = Offset.zero;
  var start = Offset.zero;
  var lastCubicControl = Offset.zero;
  var lastQuadraticControl = Offset.zero;
  var previousCommand = '';

  bool isCommand(String token) => RegExp(r'^[a-zA-Z]$').hasMatch(token);
  double number() => double.parse(tokens[index++]);
  bool arcFlag() {
    final token = tokens[index++];
    if (token.isEmpty || (token[0] != '0' && token[0] != '1')) {
      throw FormatException('Invalid SVG arc flag $token', data);
    }
    if (token.length > 1) tokens.insert(index, token.substring(1));
    return token[0] == '1';
  }

  Offset point(bool relative) {
    final value = Offset(number(), number());
    return relative ? current + value : value;
  }

  while (index < tokens.length) {
    if (isCommand(tokens[index])) {
      command = tokens[index++];
    } else if (command.isEmpty) {
      throw FormatException('SVG path starts without a command', data);
    }

    final relative = command == command.toLowerCase();
    final upper = command.toUpperCase();
    if (upper == 'Z') {
      path.close();
      current = start;
      previousCommand = 'Z';
      command = '';
      continue;
    }

    var firstMove = upper == 'M';
    do {
      switch (upper) {
        case 'M':
          final target = point(relative);
          if (firstMove) {
            path.moveTo(target.dx, target.dy);
            start = target;
            firstMove = false;
          } else {
            path.lineTo(target.dx, target.dy);
          }
          current = target;
          break;
        case 'L':
          final target = point(relative);
          path.lineTo(target.dx, target.dy);
          current = target;
          break;
        case 'H':
          final x = number() + (relative ? current.dx : 0);
          current = Offset(x, current.dy);
          path.lineTo(current.dx, current.dy);
          break;
        case 'V':
          final y = number() + (relative ? current.dy : 0);
          current = Offset(current.dx, y);
          path.lineTo(current.dx, current.dy);
          break;
        case 'C':
          final control1 = point(relative);
          final control2 = point(relative);
          final target = point(relative);
          path.cubicTo(
            control1.dx,
            control1.dy,
            control2.dx,
            control2.dy,
            target.dx,
            target.dy,
          );
          lastCubicControl = control2;
          current = target;
          break;
        case 'S':
          final control1 = previousCommand == 'C' || previousCommand == 'S'
              ? current * 2 - lastCubicControl
              : current;
          final control2 = point(relative);
          final target = point(relative);
          path.cubicTo(
            control1.dx,
            control1.dy,
            control2.dx,
            control2.dy,
            target.dx,
            target.dy,
          );
          lastCubicControl = control2;
          current = target;
          break;
        case 'Q':
          final control = point(relative);
          final target = point(relative);
          path.quadraticBezierTo(
            control.dx,
            control.dy,
            target.dx,
            target.dy,
          );
          lastQuadraticControl = control;
          current = target;
          break;
        case 'T':
          final control = previousCommand == 'Q' || previousCommand == 'T'
              ? current * 2 - lastQuadraticControl
              : current;
          final target = point(relative);
          path.quadraticBezierTo(
            control.dx,
            control.dy,
            target.dx,
            target.dy,
          );
          lastQuadraticControl = control;
          current = target;
          break;
        case 'A':
          final rx = number().abs();
          final ry = number().abs();
          final rotation = number();
          // SVG allows the two one-character flags and the following number
          // to touch, for example `01.94`. Consume exactly one character.
          final largeArc = arcFlag();
          final clockwise = arcFlag();
          final target = point(relative);
          path.arcToPoint(
            target,
            radius: Radius.elliptical(rx, ry),
            rotation: rotation,
            largeArc: largeArc,
            clockwise: clockwise,
          );
          current = target;
          break;
        default:
          throw FormatException('Unsupported SVG command $command', data);
      }
      previousCommand = upper;
    } while (index < tokens.length && !isCommand(tokens[index]));
  }
  return path;
}
