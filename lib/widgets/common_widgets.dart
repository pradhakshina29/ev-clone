import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_theme.dart';
import 'ev_logo.dart';

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : icon == null
            ? const SizedBox.shrink()
            : Icon(icon, size: 19),
        label: Text(isLoading ? 'PLEASE WAIT' : label.toUpperCase()),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.navy,
          foregroundColor: Colors.white,
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: .8,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showBack = true,
    this.showLogo = false,
  });

  final String title;
  final String? subtitle;
  final bool showBack;
  final bool showLogo;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: () => Navigator.maybePop(context),
              icon: const Icon(Icons.arrow_back_ios_new, size: 19),
              color: AppTheme.navy,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ),
        if (showLogo) ...[const SizedBox(height: 8), const AppLogo(size: 64)],
        const SizedBox(height: 20),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: AppTheme.navy,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 9),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: AppTheme.mutedBlue),
          ),
        ],
      ],
    );
  }
}

class TextInputField extends StatelessWidget {
  const TextInputField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.icon,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.validator,
    this.maxLength = 100,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData? icon;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final String? Function(String?)? validator;

  /// Hard input limit; enforced silently so the field looks unchanged.
  final int maxLength;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.navy,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          validator: validator,
          inputFormatters: [LengthLimitingTextInputFormatter(maxLength)],
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: icon == null
                ? null
                : Icon(icon, color: AppTheme.mutedBlue),
          ),
        ),
      ],
    );
  }
}

class PasswordInputField extends StatefulWidget {
  const PasswordInputField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.validator,
    this.maxLength = 128,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final String? Function(String?)? validator;
  final int maxLength;

  @override
  State<PasswordInputField> createState() => _PasswordInputFieldState();
}

class _PasswordInputFieldState extends State<PasswordInputField> {
  bool obscure = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.navy,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: widget.controller,
          obscureText: obscure,
          validator: widget.validator,
          inputFormatters: [LengthLimitingTextInputFormatter(widget.maxLength)],
          decoration: InputDecoration(
            hintText: widget.hint,
            prefixIcon: const Icon(
              Icons.lock_outline,
              color: AppTheme.mutedBlue,
            ),
            suffixIcon: IconButton(
              onPressed: () => setState(() => obscure = !obscure),
              icon: Icon(
                obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: AppTheme.mutedBlue,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> showErrorDialog(
  BuildContext context,
  String message, {
  String title = 'Please check',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        title,
        style: const TextStyle(
          color: AppTheme.navy,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Text(message),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) => EVLogoMark(size: size);
}

class VehicleCard extends StatelessWidget {
  const VehicleCard({super.key, required this.vehicle});

  final dynamic vehicle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE0E7EF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.electric_car_outlined,
                color: AppTheme.blue,
                size: 28,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  vehicle.model as String,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.navy,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          _detail('Registration Number', vehicle.registrationNumber as String),
          const SizedBox(height: 13),
          _detail('Registered Owner', vehicle.ownerName as String),
        ],
      ),
    );
  }

  Widget _detail(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: AppTheme.mutedBlue),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppTheme.navy,
        ),
      ),
    ],
  );
}
