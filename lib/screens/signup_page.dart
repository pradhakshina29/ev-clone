import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../models/user_model.dart';
import '../widgets/common_widgets.dart';
import 'vehicle_details_page.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final formKey = GlobalKey<FormState>();
  final name = TextEditingController();
  final email = TextEditingController();
  final mobile = TextEditingController();
  final city = TextEditingController();
  final password = TextEditingController();
  final confirmPassword = TextEditingController();
  bool isLoading = false;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    mobile.dispose();
    city.dispose();
    password.dispose();
    confirmPassword.dispose();
    super.dispose();
  }

  void continueToVehicleRegistration() {
    if (isLoading) return;
    if (!formKey.currentState!.validate()) {
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VehicleDetailsPage(
          pendingSignup: PendingSignup(
            name: name.text.trim(),
            email: email.text.trim(),
            mobile: mobile.text.trim(),
            city: city.text.trim(),
            password: password.text,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
            child: Column(
              children: [
                const ScreenHeader(
                  title: 'Create Your Account',
                  subtitle: 'Join EV Smart Companion',
                  showLogo: true,
                ),
                const SizedBox(height: 34),
                TextInputField(
                  controller: name,
                  label: 'Full Name',
                  maxLength: 80,
                  hint: 'Enter your full name',
                  icon: Icons.person_outline,
                  validator: (v) => v == null || v.trim().isEmpty
                      ? 'Enter your full name'
                      : null,
                ),
                const SizedBox(height: 18),
                TextInputField(
                  controller: email,
                  label: 'Email',
                  maxLength: 254,
                  hint: 'Enter your email',
                  icon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) =>
                      v == null ||
                          !RegExp(
                            r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                          ).hasMatch(v.trim())
                      ? 'Enter a valid email'
                      : null,
                ),
                const SizedBox(height: 18),
                TextInputField(
                  controller: mobile,
                  label: 'Mobile Number',
                  maxLength: 20,
                  hint: 'Enter your mobile number',
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                  validator: (v) =>
                      v == null ||
                          !RegExp(r'^[+()\d\s-]+$').hasMatch(v.trim()) ||
                          v.replaceAll(RegExp(r'\D'), '').length < 10 ||
                          v.replaceAll(RegExp(r'\D'), '').length > 15
                      ? 'Enter a valid mobile number'
                      : null,
                ),
                const SizedBox(height: 18),
                TextInputField(
                  controller: city,
                  label: 'City',
                  maxLength: 80,
                  hint: 'Enter your city',
                  icon: Icons.location_on_outlined,
                  textCapitalization: TextCapitalization.words,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Enter your city' : null,
                ),
                const SizedBox(height: 18),
                PasswordInputField(
                  controller: password,
                  label: 'Password',
                  hint: 'Create a password',
                  maxLength: 64,
                  validator: (v) =>
                      v == null ||
                          !RegExp(
                            r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,64}$',
                          ).hasMatch(v)
                      ? 'Use 8+ characters with uppercase, lowercase, and a number'
                      : null,
                ),
                const SizedBox(height: 18),
                PasswordInputField(
                  controller: confirmPassword,
                  label: 'Confirm Password',
                  hint: 'Re-enter your password',
                  maxLength: 64,
                  validator: (v) =>
                      v != password.text ? 'Passwords do not match' : null,
                ),
                const SizedBox(height: 30),
                PrimaryButton(
                  label: 'Continue',
                  onPressed: continueToVehicleRegistration,
                  isLoading: isLoading,
                ),
                const SizedBox(height: 19),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      'Already have an account?',
                      style: TextStyle(color: AppTheme.mutedBlue),
                    ),
                    TextButton(
                      onPressed: isLoading
                          ? null
                          : () => Navigator.pop(context),
                      child: const Text(
                        'Log In',
                        style: TextStyle(
                          color: AppTheme.blue,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
