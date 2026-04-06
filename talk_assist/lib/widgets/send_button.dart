import 'package:flutter/material.dart';

class SendButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool enabled;

  const SendButton({super.key, required this.onPressed, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF66A6FF), Color(0xFF7F5CFF)],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 16,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: enabled ? onPressed : null,
            child: Opacity(
              opacity: enabled ? 1.0 : 0.45,
              child: const Center(
                child: Icon(Icons.arrow_upward_rounded, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}