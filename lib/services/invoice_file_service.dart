import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

typedef InvoiceSaver = Future<void> Function(Uint8List bytes, String fileName);

/// Hands the receipt PDF to the platform: the share sheet on Android and iOS
/// (Save to Files, Drive, a PDF viewer…) and a file download on the web.
/// The PDF is never written to shared storage by the app itself.
Future<void> saveInvoicePdf(Uint8List bytes, String fileName) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(bytes, mimeType: 'application/pdf')],
      fileNameOverrides: [fileName],
      subject: 'EV Smart Companion payment receipt',
    ),
  );
}
