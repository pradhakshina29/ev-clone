import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_application_2/models/vehicle.dart';
import 'package:flutter_application_2/services/paypal_app_checkout.dart';
import 'package:flutter_application_2/widgets/charging_card_section.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_api.dart';

const _vehicle = Vehicle(
  id: 'EV006',
  model: 'EV Smart X6',
  registrationNumber: 'TN06KL1234',
  ownerName: 'Registered Vehicle Owner 6',
  vin: 'EVVIN006',
);
const _orders = 'POST /v1/vehicles/EV006/charging-card/paypal-orders';
const _capture =
    'POST /v1/vehicles/EV006/charging-card/paypal-orders/ORDER1/capture';

FakeApi _backend({Object? Function()? capture}) => FakeApi()
  ..on(
    _orders,
    (_) => {
      'orderId': 'ORDER1',
      'approvalUrl': 'https://www.sandbox.paypal.com/checkoutnow?token=ORDER1',
      'paypalAmount': 1.2,
      'paypalClientId': 'sandbox-client',
    },
  )
  ..on(
    _capture,
    (_) =>
        capture?.call() ??
        {'success': true, 'balanceAfter': 600, 'transactionId': 'tx1'},
  );

Future<void> _pumpDialog(
  WidgetTester tester,
  FakeApi api,
  PayPalApprovalLauncher launcher,
) async {
  // A small phone (Galaxy M30s is ~393 dp wide) with the keyboard closed.
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => RechargeDialog(
                  uid: 'u1',
                  vehicle: _vehicle,
                  dataService: api.dataService(),
                  currentBalance: Future.value(500),
                  approvalLauncher: launcher,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _continueToPayPal(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Continue to PayPal'));
  await tester.tap(find.text('Continue to PayPal'));
  await tester.pumpAndSettle();
}

void main() {
  group('paypalApprovalOutcomeFor', () {
    test('reads the return and cancel deep links', () {
      expect(
        paypalApprovalOutcomeFor(
          Uri.parse('evsmartcompanion://paypal-return?token=ORDER1&PayerID=P'),
          'ORDER1',
        ),
        PayPalApprovalOutcome.returned,
      );
      expect(
        paypalApprovalOutcomeFor(
          Uri.parse('evsmartcompanion://paypal-cancel?token=ORDER1'),
          'ORDER1',
        ),
        PayPalApprovalOutcome.cancelled,
      );
    });

    test('rejects another order or an unknown link', () {
      expect(
        () => paypalApprovalOutcomeFor(
          Uri.parse('evsmartcompanion://paypal-return?token=OTHER'),
          'ORDER1',
        ),
        throwsStateError,
      );
      expect(
        () => paypalApprovalOutcomeFor(
          Uri.parse('evsmartcompanion://spotify-callback?code=x'),
          'ORDER1',
        ),
        throwsStateError,
      );
    });
  });

  group('Android PayPal recharge dialog', () {
    testWidgets('returns from PayPal, captures once and offers the invoice', (
      tester,
    ) async {
      final api = _backend();
      Uri? opened;
      await _pumpDialog(tester, api, (uri, orderId) async {
        opened = uri;
        return PayPalApprovalOutcome.returned;
      });

      await _continueToPayPal(tester);

      expect(opened?.host, 'www.sandbox.paypal.com');
      final created = api.requestsTo(_orders).single;
      expect(jsonDecode(created.body), {'amountInr': 100, 'returnTo': 'app'});
      expect(api.requestsTo(_capture), hasLength(1));
      expect(find.text('Recharge successful'), findsOneWidget);
      expect(find.text('Download invoice'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a closed PayPal tab never freezes the dialog', (tester) async {
      var approved = false;
      final api = _backend(
        capture: () => approved
            ? null
            : const FakeReply(409, {
                'error': {
                  'code': 'paypal_not_approved',
                  'message': 'Not approved yet.',
                },
              }),
      );
      await _pumpDialog(
        tester,
        api,
        (_, _) async => PayPalApprovalOutcome.dismissed,
      );

      await _continueToPayPal(tester);
      expect(find.textContaining('PayPal was closed'), findsOneWidget);

      // Confirming before paying keeps the order open instead of failing.
      await tester.ensureVisible(find.text('Confirm payment'));
      await tester.tap(find.text('Confirm payment'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('not confirmed this payment yet'),
        findsOneWidget,
      );
      expect(find.text('Recharge successful'), findsNothing);

      approved = true;
      await tester.ensureVisible(find.text('Confirm payment'));
      await tester.tap(find.text('Confirm payment'));
      await tester.pumpAndSettle();
      expect(find.text('Recharge successful'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a cancelled payment can be closed without capturing', (
      tester,
    ) async {
      final api = _backend();
      await _pumpDialog(
        tester,
        api,
        (_, _) async => PayPalApprovalOutcome.cancelled,
      );

      await _continueToPayPal(tester);
      expect(
        find.textContaining('Payment cancelled in PayPal'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(RechargeDialog), findsNothing);
      expect(api.requestsTo(_capture), isEmpty);
    });

    testWidgets('fits a small phone with the keyboard open', (tester) async {
      await _pumpDialog(
        tester,
        _backend(),
        (_, _) async => PayPalApprovalOutcome.dismissed,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await _continueToPayPal(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Cancel'));
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
    });

    testWidgets('waiting for PayPal still offers Confirm and Cancel', (
      tester,
    ) async {
      final pending = Completer<PayPalApprovalOutcome>();
      await _pumpDialog(tester, _backend(), (_, _) => pending.future);

      await _continueToPayPal(tester);

      expect(find.textContaining('Waiting for PayPal'), findsOneWidget);
      expect(find.text('Confirm payment'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      // A late result after the user moved on is ignored.
      await tester.ensureVisible(find.text('Confirm payment'));
      await tester.tap(find.text('Confirm payment'));
      await tester.pumpAndSettle();
      pending.complete(PayPalApprovalOutcome.cancelled);
      await tester.pumpAndSettle();
      expect(find.text('Recharge successful'), findsOneWidget);
    });
  });
}
