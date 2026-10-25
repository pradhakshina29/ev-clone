import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// How the payer came back from the PayPal approval page on Android/iOS.
enum PayPalApprovalOutcome {
  /// PayPal redirected to evsmartcompanion://paypal-return: approved, ready
  /// for the backend capture.
  returned,

  /// PayPal redirected to evsmartcompanion://paypal-cancel.
  cancelled,

  /// The browser tab was closed (or the app reopened) without a redirect;
  /// the payer may or may not have paid.
  dismissed,
}

/// Opens [approvalUrl] and completes when the payer comes back.
typedef PayPalApprovalLauncher =
    Future<PayPalApprovalOutcome> Function(Uri approvalUrl, String orderId);

const paypalCallbackScheme = 'evsmartcompanion';
const paypalReturnHost = 'paypal-return';
const paypalCancelHost = 'paypal-cancel';

/// Shows PayPal in a Custom Tab (Android) / ASWebAuthenticationSession (iOS)
/// and waits for the return/cancel deep link the backend set on the order.
Future<PayPalApprovalOutcome> openPayPalApproval(
  Uri approvalUrl,
  String orderId,
) async {
  final String callback;
  try {
    callback = await FlutterWebAuth2.authenticate(
      url: approvalUrl.toString(),
      callbackUrlScheme: paypalCallbackScheme,
    );
  } on PlatformException catch (error) {
    // The user closed the tab or came back to the app another way.
    if (error.code == 'CANCELED') return PayPalApprovalOutcome.dismissed;
    rethrow;
  }
  return paypalApprovalOutcomeFor(Uri.parse(callback), orderId);
}

/// Reads PayPal's redirect, which carries the order ID as `token`.
@visibleForTesting
PayPalApprovalOutcome paypalApprovalOutcomeFor(Uri callback, String orderId) {
  if (callback.scheme != paypalCallbackScheme) {
    throw StateError('PayPal returned an unexpected link.');
  }
  final token = callback.queryParameters['token'];
  if (token != null && token.isNotEmpty && token != orderId) {
    throw StateError('PayPal returned a different order.');
  }
  return switch (callback.host) {
    paypalReturnHost => PayPalApprovalOutcome.returned,
    paypalCancelHost => PayPalApprovalOutcome.cancelled,
    _ => throw StateError('PayPal returned an unexpected link.'),
  };
}
