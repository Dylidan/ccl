import 'package:flutter/material.dart';

class AnimatedGradientBackground extends StatefulWidget {
  const AnimatedGradientBackground({super.key});

  @override
  State<AnimatedGradientBackground> createState() => _AnimatedGradientBackgroundState();
}

class _AnimatedGradientBackgroundState extends State<AnimatedGradientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 10))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final t = _controller.value;
        final a = Alignment.lerp(Alignment.topLeft, Alignment.topRight, t)!;
        final b = Alignment.lerp(Alignment.bottomRight, Alignment.bottomLeft, t)!;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: a,
              end: b,
              colors: const [Color(0xFF0B1220), Color(0xFF101A33), Color(0xFF14102A)],
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.lerp(const Alignment(-0.6, -0.6), const Alignment(0.6, 0.2), t)!,
                radius: 1.2,
                colors: [
                  const Color(0xFF7F5CFF).withOpacity(0.22),
                  const Color(0xFF66A6FF).withOpacity(0.10),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.35, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}