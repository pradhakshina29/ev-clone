import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'services/api/api_config.dart';
import 'screens/auth_gate.dart';
import 'services/vehicle_alert_coordinator.dart';
import 'services/vehicle_health_history.dart';
import 'widgets/ev_logo.dart';

/// Let app-wide services show dialogs and SnackBars over any screen.
final appNavigatorKey = GlobalKey<NavigatorState>();
final appScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ensureApiBaseUrlConfigured();
  VehicleAlertCoordinator.startShared(
    navigatorKey: appNavigatorKey,
    messengerKey: appScaffoldMessengerKey,
  );
  VehicleHealthHistory.startShared();
  runApp(const EVSmartCompanionApp());
}

class EVSmartCompanionApp extends StatelessWidget {
  const EVSmartCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: appScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.data,
      themeMode: ThemeMode.light,
      home: const EVHomePage(),
    );
  }
}

class EVHomePage extends StatefulWidget {
  const EVHomePage({super.key});

  @override
  State<EVHomePage> createState() => _EVHomePageState();
}

class _EVHomePageState extends State<EVHomePage> with TickerProviderStateMixin {
  late AnimationController logoController;
  late AnimationController textController;

  late Animation<double> logoScale;
  late Animation<double> logoFade;

  late Animation<double> titleFade;
  late Animation<Offset> titleSlide;

  late Animation<double> subtitleFade;
  late Animation<Offset> subtitleSlide;

  @override
  void initState() {
    super.initState();

    // ============================================================
    // LOGO ANIMATION
    // ============================================================

    logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    logoScale = Tween<double>(begin: 0.65, end: 1.0).animate(
      CurvedAnimation(parent: logoController, curve: Curves.easeOutBack),
    );

    logoFade = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: logoController, curve: Curves.easeIn));

    // ============================================================
    // TEXT ANIMATION
    // ============================================================

    textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    titleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: textController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );

    titleSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: textController,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
          ),
        );

    subtitleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: textController,
        curve: const Interval(0.35, 1.0, curve: Curves.easeIn),
      ),
    );

    subtitleSlide = Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: textController,
            curve: const Interval(0.35, 1.0, curve: Curves.easeOut),
          ),
        );

    // ============================================================
    // START LOGO
    // ============================================================

    logoController.forward();

    // ============================================================
    // START TEXT AFTER LOGO HAS STARTED
    // ============================================================

    Future.delayed(const Duration(milliseconds: 700), () async {
      if (!mounted) return;

      await textController.forward();

      if (!mounted) return;

      // ========================================================
      // 1 SECOND PAUSE AFTER ANIMATION
      // ========================================================

      await Future.delayed(const Duration(seconds: 1));

      if (!mounted) return;

      // ========================================================
      // SMOOTH TRANSITION TO LOGIN PAGE
      // ========================================================

      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 700),

          pageBuilder: (context, animation, secondaryAnimation) {
            return const AuthGate();
          },

          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeInOut,
              ),
              child: child,
            );
          },
        ),
      );
    });
  }

  @override
  void dispose() {
    logoController.dispose();
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,

      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // ==================================================
                // ANIMATED LOGO
                // ==================================================
                FadeTransition(
                  opacity: logoFade,
                  child: ScaleTransition(
                    scale: logoScale,
                    child: EVLogo(
                      width: math.min(
                        340,
                        MediaQuery.sizeOf(context).width - 48,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // ==================================================
                // ANIMATED TITLE
                // ==================================================
                FadeTransition(
                  opacity: titleFade,
                  child: SlideTransition(
                    position: titleSlide,
                    child: const Text(
                      "EV Smart Companion",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF071326),
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // ==================================================
                // ANIMATED SUBTITLE
                // ==================================================
                FadeTransition(
                  opacity: subtitleFade,
                  child: SlideTransition(
                    position: subtitleSlide,
                    child: const Text(
                      "DRIVE SMARTER. CHARGE SIMPLER.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF6F8EAF),
                        letterSpacing: 2.2,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
