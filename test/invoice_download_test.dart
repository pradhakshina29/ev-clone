import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_application_2/services/data_service.dart';
import 'package:flutter_application_2/services/invoice_file_service.dart';
import 'package:flutter_application_2/widgets/charging_card_section.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/fake_api.dart';

const _invoicePath =
    '/v1/vehicles/EV001/charging-card/transactions/tx1/invoice';
final _pdf = Uint8List.fromList(utf8.encode('%PDF-1.3 test'));

FakeApi _api({required bool pdfOk}) {
  final api = FakeApi()
    ..on(
      'GET $_invoicePath',
      (_) => {
        'invoice': {'invoiceNumber': 'EVSC-TEST-2026-000001'},
      },
    )
    ..on(
      'GET $_invoicePath.pdf',
      (_) => pdfOk
          ? http.Response.bytes(_pdf, 200)
          : const FakeReply(409, {
              'error': {
                'code': 'invoice_unavailable',
                'message':
                    'Invoices are available only for verified PayPal recharges.',
              },
            }),
    );
  return api;
}

Widget _button(FakeApi api, InvoiceSaver saver) => MaterialApp(
  home: Scaffold(
    body: InvoiceDownloadButton(
      dataService: DataService(api: api.client()),
      vehicleId: 'EV001',
      transactionId: 'tx1',
      saver: saver,
    ),
  ),
);

void main() {
  test(
    'downloads the receipt PDF with its invoice number as file name',
    () async {
      final api = _api(pdfOk: true);
      final (fileName, bytes) = await DataService(
        api: api.client(),
      ).downloadRechargeInvoice(vehicleId: 'EV001', transactionId: 'tx1');
      expect(fileName, 'EVSC-TEST-2026-000001.pdf');
      expect(bytes, _pdf);
      expect(api.requests.every((r) => r.method == 'GET'), isTrue);
      expect(api.requests.first.headers['Authorization'], 'Bearer test-token');
    },
  );

  testWidgets('Download invoice hands the PDF to the saver', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      _button(_api(pdfOk: true), (bytes, name) async => saved.add(name)),
    );
    await tester.tap(find.text('Download invoice'));
    await tester.pumpAndSettle();
    expect(saved, ['EVSC-TEST-2026-000001.pdf']);
    expect(find.textContaining('could not'), findsNothing);
  });

  testWidgets('shows the backend reason when no receipt is available', (
    tester,
  ) async {
    var saverCalled = false;
    await tester.pumpWidget(
      _button(_api(pdfOk: false), (_, _) async => saverCalled = true),
    );
    await tester.tap(find.text('Download invoice'));
    await tester.pumpAndSettle();
    expect(saverCalled, isFalse);
    expect(
      find.text('Invoices are available only for verified PayPal recharges.'),
      findsOneWidget,
    );
    // The button stays usable for a retry.
    expect(find.text('Download invoice'), findsOneWidget);
  });
}
