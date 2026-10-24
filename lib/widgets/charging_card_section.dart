import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../models/charging_card.dart';
import '../models/vehicle.dart';
import '../services/api/api_client.dart';
import '../services/data_service.dart';
import '../services/invoice_file_service.dart';
import '../services/paypal_web_checkout_bridge.dart';

class ChargingCardSection extends StatelessWidget {
  const ChargingCardSection({
    required this.uid,
    required this.dataService,
    super.key,
  });

  final String uid;
  final DataService dataService;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Vehicle?>(
      stream: dataService.watchConnectedVehicle(uid),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _CardMessage(
            icon: Icons.cloud_off_rounded,
            message:
                'Connected vehicle data could not be loaded. Check your connection and try again.',
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final vehicle = snapshot.data;
        if (vehicle == null) {
          return const _CardMessage(
            icon: Icons.directions_car_filled_outlined,
            message: 'No active connected vehicle is linked to this account.',
          );
        }
        return StreamBuilder<ChargingCard?>(
          key: ValueKey(vehicle.id),
          stream: dataService.watchChargingCard(
            uid,
            vehicleId: vehicle.id,
            vehicleModel: vehicle.model,
            vehicleRegistration: vehicle.registrationNumber,
          ),
          builder: (context, cardSnapshot) {
            if (cardSnapshot.hasError) {
              return const _CardMessage(
                icon: Icons.cloud_off_rounded,
                message:
                    'Charging card data could not be loaded. Check your connection and try again.',
              );
            }
            if (cardSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            return _buildCardContent(context, vehicle, cardSnapshot.data);
          },
        );
      },
    );
  }

  Widget _buildCardContent(
    BuildContext context,
    Vehicle vehicle,
    ChargingCard? card,
  ) {
    if (card != null &&
        (card.vehicleId != vehicle.id ||
            card.vehicleModel != vehicle.model ||
            card.vehicleRegistrationNumber != vehicle.registrationNumber ||
            card.vehicleVin != vehicle.vin)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CardMessage(
            icon: Icons.warning_amber_rounded,
            message: 'Charging card does not match the selected vehicle.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _openCardForm(context, vehicle, card: card),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Review card details'),
          ),
        ],
      );
    }
    final registerButton = FilledButton.icon(
      onPressed: () => _openCardForm(context, vehicle),
      icon: const Icon(Icons.add_card_rounded),
      label: const Text('Register Charging Card'),
    );
    return RefreshIndicator(
      onRefresh: dataService.refresh,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'MY CHARGING CARD',
              style: TextStyle(
                color: AppTheme.navy,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            _ConnectedVehicleSelector(
              uid: uid,
              vehicle: vehicle,
              dataService: dataService,
            ),
            const SizedBox(height: 12),
            if (card == null) ...[
              const _CardMessage(
                icon: Icons.credit_card_off_rounded,
                message: 'No charging card registered for this vehicle.',
              ),
              const SizedBox(height: 14),
              registerButton,
            ] else ...[
              _ChargingCardVisual(card: card),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'CARD DETAILS',
                      style: TextStyle(
                        color: AppTheme.navy,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        _openCardForm(context, vehicle, card: card),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                ],
              ),
              _CardValue(
                label: 'Card type',
                value: card.cardType ?? 'Not available',
              ),
              _CardValue(
                label: 'Card number',
                value: card.displayCardNumber ?? 'Not available',
              ),
              _CardValue(
                label: 'Card holder',
                value: card.cardHolderName ?? 'Not available',
              ),
              _CardValue(
                label: 'Vehicle',
                value:
                    '${card.vehicleModel}\n${card.vehicleRegistrationNumber}\n${card.vehicleId}',
              ),
              _CardValue(
                label: 'VIN',
                value: card.vehicleVin ?? 'Not available',
              ),
              _CardValue(
                label: 'Currency',
                value: card.currency ?? 'Not available',
              ),
              _CardStatus(value: card.status ?? 'Not available'),
              _CardValue(
                label: 'Last recharge',
                value: card.lastRechargeAmount == null
                    ? 'Not available'
                    : _formatMoney(card.lastRechargeAmount!, card.currency),
              ),
              _CardValue(
                label: 'Last recharge date',
                value: card.lastRechargeDate == null
                    ? 'Not available'
                    : _dateLabel(card.lastRechargeDate!),
              ),
              _CardValue(
                label: 'Expiry',
                value: card.expiryDate == null
                    ? 'Not available'
                    : _dateLabel(card.expiryDate!),
              ),
              _CardValue(
                label: 'Registered',
                value: card.registeredAt == null
                    ? 'Not available'
                    : _dateLabel(card.registeredAt!),
              ),
              const SizedBox(height: 12),
              const Text(
                'TRANSACTION HISTORY',
                style: TextStyle(
                  color: AppTheme.navy,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              _RecentTransactionSummary(
                uid: uid,
                vehicleId: vehicle.id,
                dataService: dataService,
              ),
            ],
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: () => _showRechargeMessage(context, vehicle),
              icon: const Icon(Icons.add_card_rounded),
              label: const Text('Recharge'),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () => _showTransactionHistory(context, vehicle.id),
              icon: const Icon(Icons.receipt_long_rounded),
              label: const Text('Transaction History'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openCardForm(
    BuildContext context,
    Vehicle vehicle, {
    ChargingCard? card,
  }) async {
    final savedVehicleId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _ChargingCardForm(
          uid: uid,
          dataService: dataService,
          connectedVehicle: vehicle,
          existingCard: card,
        ),
      ),
    );
    if (savedVehicleId != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Charging card details saved for vehicle $savedVehicleId.',
          ),
        ),
      );
    }
  }

  void _showRechargeMessage(BuildContext context, Vehicle vehicle) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _RechargeDialog(
        uid: uid,
        vehicle: vehicle,
        dataService: dataService,
        currentBalance: dataService
            .getChargingCard(uid, vehicleId: vehicle.id)
            .then((card) => card?.balance ?? 0),
      ),
    );
  }

  void _showTransactionHistory(BuildContext context, String vehicleId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.76,
        child: _TransactionHistory(
          uid: uid,
          vehicleId: vehicleId,
          dataService: dataService,
        ),
      ),
    );
  }
}

class _ConnectedVehicleSelector extends StatefulWidget {
  const _ConnectedVehicleSelector({
    required this.uid,
    required this.vehicle,
    required this.dataService,
  });

  final String uid;
  final Vehicle vehicle;
  final DataService dataService;

  @override
  State<_ConnectedVehicleSelector> createState() =>
      _ConnectedVehicleSelectorState();
}

class _ConnectedVehicleSelectorState extends State<_ConnectedVehicleSelector> {
  late final Stream<List<Vehicle>> _vehicles;
  bool _switching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _vehicles = widget.dataService.watchLinkedVehicles(widget.uid);
  }

  Future<void> _selectVehicle(String vehicleId) async {
    if (_switching || vehicleId == widget.vehicle.id) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      await widget.dataService.setConnectedVehicle(
        uid: widget.uid,
        vehicleId: vehicleId,
      );
    } catch (error, stackTrace) {
      debugPrint('Could not switch connected vehicle: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Vehicle>>(
    stream: _vehicles,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _CardValue(
          label: 'Connected vehicle',
          value:
              '${widget.vehicle.model}\n${widget.vehicle.registrationNumber}\n${widget.vehicle.id}',
        );
      }
      final vehicles = {
        for (final linkedVehicle in snapshot.data ?? <Vehicle>[])
          linkedVehicle.id: linkedVehicle,
        widget.vehicle.id: widget.vehicle,
      }.values.toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey(widget.vehicle.id),
            initialValue: widget.vehicle.id,
            decoration: const InputDecoration(
              labelText: 'Connected vehicle',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final linkedVehicle in vehicles)
                DropdownMenuItem(
                  value: linkedVehicle.id,
                  child: Text(
                    '${linkedVehicle.model}\n${linkedVehicle.registrationNumber} · ${linkedVehicle.id}',
                  ),
                ),
            ],
            onChanged: _switching
                ? null
                : (vehicleId) {
                    if (vehicleId != null) _selectVehicle(vehicleId);
                  },
          ),
          if (_switching) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ],
      );
    },
  );
}

class _ChargingCardForm extends StatefulWidget {
  const _ChargingCardForm({
    required this.uid,
    required this.dataService,
    required this.connectedVehicle,
    this.existingCard,
  });

  final String uid;
  final DataService dataService;
  final Vehicle connectedVehicle;
  final ChargingCard? existingCard;

  @override
  State<_ChargingCardForm> createState() => _ChargingCardFormState();
}

class _ChargingCardFormState extends State<_ChargingCardForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _typeController;
  late final TextEditingController _numberController;
  late final TextEditingController _holderController;
  late final Stream<List<Vehicle>> _linkedVehiclesStream;
  String? _selectedVehicleId;
  DateTime? _expiryDate;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final card = widget.existingCard;
    _typeController = TextEditingController(text: card?.cardType ?? '');
    _numberController = TextEditingController();
    _holderController = TextEditingController(text: card?.cardHolderName ?? '');
    _expiryDate = card?.expiryDate;
    _selectedVehicleId = widget.connectedVehicle.id;
    _linkedVehiclesStream = widget.dataService.watchLinkedVehicles(widget.uid);
  }

  @override
  void dispose() {
    _typeController.dispose();
    _numberController.dispose();
    _holderController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    debugPrint('[CARD PROD DEBUG] REGISTER BUTTON PRESSED');
    if (_saving) {
      debugPrint('[CARD PROD DEBUG] Validation: already saving (blocked)');
      return;
    }
    final isEditing = widget.existingCard != null;
    final cardTypeValid = _typeController.text.trim().isNotEmpty;
    final cardNumber = _numberController.text.trim();
    final cardNumberValid =
        (isEditing && cardNumber.isEmpty) ||
        RegExp(
          r'^[A-Za-z0-9]{4,32}$',
        ).hasMatch(cardNumber.replaceAll(RegExp(r'[\s-]'), ''));
    final cardHolderValid = _holderController.text.trim().isNotEmpty;
    debugPrint(
      '[CARD PROD DEBUG] Validation: card type valid = $cardTypeValid',
    );
    debugPrint(
      '[CARD PROD DEBUG] Validation: card number valid = $cardNumberValid',
    );
    debugPrint(
      '[CARD PROD DEBUG] Validation: card holder valid = $cardHolderValid',
    );
    final formValid = _formKey.currentState!.validate();
    debugPrint('[CARD PROD DEBUG] Validation: form valid = $formValid');
    if (!formValid) return;

    final vehicleId = _selectedVehicleId ?? widget.connectedVehicle.id;
    debugPrint(
      '[CARD PROD DEBUG] Validation: selected vehicle ID non-empty = '
      '${vehicleId.isNotEmpty}',
    );
    if (vehicleId.isEmpty) {
      setState(() => _error = 'Link a vehicle to your account first.');
      return;
    }
    debugPrint(
      '[CARD PROD DEBUG] Validation: expiry date selected = '
      '${_expiryDate != null}',
    );
    if (_expiryDate == null) {
      setState(() => _error = 'Choose the card expiry date.');
      return;
    }

    // Keep the full card number on this device: only the last four characters
    // are passed on, and the data layer stores the masked form.
    final compactNumber = cardNumber.replaceAll(RegExp(r'[\s-]'), '');
    final cardLastFour = compactNumber.length < 4
        ? null
        : compactNumber.substring(compactNumber.length - 4);

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.existingCard == null) {
        debugPrint('[CARD PROD DEBUG] Calling registerChargingCard()');
        await widget.dataService.registerChargingCard(
          uid: widget.uid,
          cardType: _typeController.text,
          cardLastFour: cardLastFour ?? '',
          cardHolderName: _holderController.text,
          vehicleId: vehicleId,
          expiryDate: _expiryDate,
        );
      } else {
        await widget.dataService.updateChargingCardDetails(
          uid: widget.uid,
          cardType: _typeController.text,
          cardLastFour: cardLastFour,
          cardHolderName: _holderController.text,
          vehicleId: vehicleId,
          expiryDate: _expiryDate,
        );
      }
      if (vehicleId != widget.connectedVehicle.id) {
        await widget.dataService.setConnectedVehicle(
          uid: widget.uid,
          vehicleId: vehicleId,
        );
      }
      if (mounted) Navigator.pop(context, vehicleId);
    } catch (error, stackTrace) {
      debugPrint('Could not save charging-card details: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = switch (error) {
          StateError stateError => stateError.toString().replaceFirst(
            'Bad state: ',
            '',
          ),
          ArgumentError argumentError => argumentError.toString().replaceFirst(
            'Invalid argument(s): ',
            '',
          ),
          ApiException apiError => apiError.message,
          _ => 'Charging-card details could not be saved. $error',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existingCard != null;
    final vehicle = widget.connectedVehicle;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isEditing ? 'Edit Charging Card' : 'Register Charging Card',
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 21,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enter your charging card details. Do not enter a CVV, PIN, or payment password.',
              style: TextStyle(color: AppTheme.mutedBlue),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _typeController,
              inputFormatters: [LengthLimitingTextInputFormatter(40)],
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Card type',
                hintText: 'For example, EV charging card',
              ),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _numberController,
              inputFormatters: [LengthLimitingTextInputFormatter(40)],
              decoration: const InputDecoration(
                labelText: 'Card number',
                hintText: 'Enter a number, or leave empty to keep it',
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (!isEditing && text.isEmpty) {
                  return 'Enter a card number.';
                }
                if (text.isNotEmpty &&
                    !RegExp(
                      r'^[A-Za-z0-9]{4,32}$',
                    ).hasMatch(text.replaceAll(RegExp(r'[\s-]'), ''))) {
                  return 'Enter a valid card number.';
                }
                return null;
              },
            ),
            if (isEditing) ...[
              const SizedBox(height: 5),
              const Text(
                'Leave the card number blank to keep the existing masked number. A replacement number is stored only in masked form.',
                style: TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _holderController,
              inputFormatters: [LengthLimitingTextInputFormatter(80)],
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Card holder name'),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: 'Expiry date'),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _expiryDate == null
                          ? 'Not set'
                          : _dateLabel(_expiryDate!),
                      style: const TextStyle(color: AppTheme.navy),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () async {
                            final now = DateTime.now();
                            final selected = await showDatePicker(
                              context: context,
                              initialDate:
                                  _expiryDate ??
                                  DateTime(now.year + 1, now.month, now.day),
                              firstDate: DateTime(now.year, now.month, now.day),
                              lastDate: DateTime(now.year + 30),
                            );
                            if (selected != null && mounted) {
                              setState(() => _expiryDate = selected);
                            }
                          },
                    child: const Text('Choose'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<Vehicle>>(
              stream: _linkedVehiclesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text(
                    'Linked vehicles could not be loaded. Check your connection and try again.',
                    style: TextStyle(color: Colors.redAccent),
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const LinearProgressIndicator();
                }
                final linkedVehicles = {
                  for (final linkedVehicle in snapshot.data ?? <Vehicle>[])
                    linkedVehicle.id: linkedVehicle,
                  vehicle.id: vehicle,
                }.values.toList();
                final selectedVehicleId =
                    linkedVehicles.any((item) => item.id == _selectedVehicleId)
                    ? _selectedVehicleId!
                    : vehicle.id;
                return DropdownButtonFormField<String>(
                  initialValue: selectedVehicleId,
                  decoration: const InputDecoration(
                    labelText: 'Vehicle association',
                  ),
                  items: [
                    for (final linkedVehicle in linkedVehicles)
                      DropdownMenuItem(
                        value: linkedVehicle.id,
                        child: Text(
                          '${linkedVehicle.model} · ${linkedVehicle.registrationNumber} · ${linkedVehicle.id}',
                        ),
                      ),
                  ],
                  onChanged: _saving || isEditing
                      ? null
                      : (value) => setState(() {
                          _selectedVehicleId = value;
                        }),
                );
              },
            ),
            if (!isEditing) ...[
              const SizedBox(height: 10),
              Text(
                'New cards start with a balance of ${_currency(0, 'INR')}.',
                style: const TextStyle(color: AppTheme.mutedBlue, fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isEditing ? 'Save Changes' : 'Register Card'),
            ),
          ],
        ),
      ),
    );
  }

  String? _requiredValidator(String? value) =>
      value == null || value.trim().isEmpty ? 'This field is required.' : null;
}

class _RechargeDialog extends StatefulWidget {
  const _RechargeDialog({
    required this.uid,
    required this.vehicle,
    required this.dataService,
    required this.currentBalance,
  });

  final String uid;
  final Vehicle vehicle;
  final DataService dataService;
  final Future<double> currentBalance;

  @override
  State<_RechargeDialog> createState() => _RechargeDialogState();
}

class _RechargeDialogState extends State<_RechargeDialog> {
  static const List<double> _presetAmounts = [100, 250, 500, 1000];
  static const double _demoExchangeRateInrToUsd = 0.012;

  late double _selectedAmount;
  bool _processing = false;
  String? _error;
  String? _orderId;
  String? _approvalUrl;
  bool _success = false;
  double? _balanceAfter;
  String? _rechargeTransactionId;
  double? _paypalAmount;
  String? _paypalClientId;
  String? _statusMessage;
  bool _webCheckoutReady = false;
  bool _awaitingWebCapture = false;
  StreamSubscription<PayPalWebCheckoutEvent>? _webCheckoutSubscription;

  @override
  void initState() {
    super.initState();
    _selectedAmount = _presetAmounts.first;
    if (kIsWeb) {
      initializePayPalWebCheckoutBridge();
      _webCheckoutSubscription = paypalWebCheckoutEvents.listen(
        _handleWebCheckoutEvent,
      );
    }
  }

  @override
  void dispose() {
    _webCheckoutSubscription?.cancel();
    super.dispose();
  }

  void _handleWebCheckoutEvent(PayPalWebCheckoutEvent event) {
    if (!mounted) return;
    switch (event.status) {
      case PayPalWebCheckoutStatus.approved:
        if (event.orderId != _orderId) {
          finishPayPalWebCheckoutCapture(success: false);
          _showError('PayPal returned an unexpected order.');
          return;
        }
        _awaitingWebCapture = true;
        unawaited(_captureApprovedOrder(event.orderId));
        return;
      case PayPalWebCheckoutStatus.cancelled:
        setState(() {
          _processing = false;
          _statusMessage = 'Payment cancelled. You can try checkout again.';
        });
        return;
      case PayPalWebCheckoutStatus.failed:
        setState(() {
          _processing = false;
          _statusMessage = 'Payment failed.';
          _error = event.message ?? 'PayPal checkout could not be completed.';
        });
        return;
    }
  }

  double _verifiedBalanceAfter(Map<String, dynamic> capture) {
    final balanceAfter = capture['balanceAfter'];
    if (capture['success'] != true || balanceAfter is! num) {
      throw StateError(
        'The backend did not verify a completed PayPal capture.',
      );
    }
    return balanceAfter.toDouble();
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  Future<void> _createOrder() async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
      _statusMessage = 'Creating PayPal order...';
    });
    try {
      debugPrint('[PayPal Recharge] Calling createPayPalRechargeOrder');
      final response = await widget.dataService.createPayPalRechargeOrder(
        uid: widget.uid,
        vehicleId: widget.vehicle.id,
        amount: _selectedAmount,
        currency: 'INR',
      );
      final orderId = (response['orderId'] ?? '').toString();
      final approvalUrl = (response['approvalUrl'] ?? '').toString();
      final paypalAmount = response['paypalAmount'];
      final paypalClientId = (response['paypalClientId'] ?? '').toString();
      if (orderId.isEmpty) {
        throw StateError(
          'The recharge request did not return a valid PayPal order.',
        );
      }
      if (paypalAmount is! num) {
        throw StateError(
          'The recharge request did not return its PayPal Sandbox amount.',
        );
      }
      setState(() {
        _orderId = orderId;
        _paypalAmount = paypalAmount.toDouble();
        _paypalClientId = paypalClientId;
      });

      if (kIsWeb) {
        await _prepareWebCheckout();
      } else {
        final approvalUri = Uri.tryParse(approvalUrl);
        if (approvalUri == null ||
            approvalUri.scheme != 'https' ||
            (approvalUri.host != 'sandbox.paypal.com' &&
                !approvalUri.host.endsWith('.sandbox.paypal.com'))) {
          throw StateError(
            'PayPal Sandbox did not return a valid approval link.',
          );
        }
        setState(() {
          _approvalUrl = approvalUrl;
          _statusMessage = 'Waiting for approval in external PayPal checkout.';
        });
        final opened = await launchUrl(
          approvalUri,
          mode: LaunchMode.externalApplication,
        );
        if (!opened) {
          setState(() {
            _statusMessage = 'Payment failed.';
            _error = 'Could not open external PayPal Sandbox checkout.';
          });
        } else {
          setState(() => _processing = false);
        }
      }
    } catch (error) {
      setState(() {
        _processing = false;
        _statusMessage = 'Payment failed.';
        _error = error.toString();
      });
    }
  }

  Future<void> _prepareWebCheckout() async {
    final orderId = _orderId;
    final clientId = _paypalClientId;
    if (orderId == null ||
        orderId.isEmpty ||
        clientId == null ||
        clientId.isEmpty) {
      _showError('PayPal Web checkout configuration is unavailable.');
      setState(() {
        _processing = false;
        _statusMessage = 'Payment failed.';
      });
      return;
    }
    setState(() {
      _processing = true;
      _statusMessage = 'Opening PayPal checkout...';
      _error = null;
    });
    try {
      await preparePayPalWebCheckout(clientId: clientId, orderId: orderId);
      if (!mounted) return;
      setState(() {
        _webCheckoutReady = true;
        _processing = false;
        _statusMessage = 'PayPal popup checkout is ready.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _statusMessage = 'Payment failed.';
        _error = error.toString();
      });
    }
  }

  void _startWebCheckout() {
    if (_processing || !_webCheckoutReady) return;
    setState(() {
      _statusMessage = 'Waiting for approval...';
      _error = null;
    });
    try {
      startPayPalWebCheckout();
    } catch (error) {
      setState(() {
        _statusMessage = 'Payment failed.';
        _error = error.toString();
      });
    }
  }

  Future<void> _captureApprovedOrder([String? approvedOrderId]) async {
    final orderId = _orderId;
    if (_processing || orderId == null || orderId.isEmpty) return;
    setState(() {
      _processing = true;
      _error = null;
      _statusMessage = 'Processing payment...';
    });
    try {
      debugPrint('[PayPal Recharge] Calling capturePayPalRechargeOrder');
      final capture = await widget.dataService.capturePayPalRechargeOrder(
        uid: widget.uid,
        vehicleId: widget.vehicle.id,
        orderId: approvedOrderId ?? orderId,
      );
      final balanceAfter = _verifiedBalanceAfter(capture);
      final transactionId = capture['transactionId'];
      if (_awaitingWebCapture) {
        finishPayPalWebCheckoutCapture(success: true);
        _awaitingWebCapture = false;
      }
      setState(() {
        _success = true;
        _balanceAfter = balanceAfter;
        _rechargeTransactionId = transactionId is String ? transactionId : null;
        _processing = false;
        _statusMessage = 'Payment successful.';
      });
    } catch (error) {
      if (_awaitingWebCapture) {
        finishPayPalWebCheckoutCapture(success: false);
        _awaitingWebCapture = false;
      }
      setState(() {
        _processing = false;
        _statusMessage = 'Payment failed.';
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: FutureBuilder<double>(
            future: widget.currentBalance,
            builder: (context, snapshot) {
              final currentBalance = snapshot.data ?? 0.0;
              final previewPaypalAmount = double.parse(
                (_selectedAmount * _demoExchangeRateInrToUsd).toStringAsFixed(
                  2,
                ),
              );
              final paypalAmount = _paypalAmount ?? previewPaypalAmount;
              if (_success) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF16845B),
                      size: 52,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Recharge successful',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppTheme.navy,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '₹${_selectedAmount.toStringAsFixed(2)} has been added to your charging card.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.mutedBlue),
                    ),
                    const SizedBox(height: 12),
                    _CardValue(
                      label: 'Current balance',
                      value: _formatMoney(
                        _balanceAfter ?? currentBalance,
                        'INR',
                      ),
                    ),
                    if (_rechargeTransactionId case final transactionId?) ...[
                      const SizedBox(height: 12),
                      InvoiceDownloadButton(
                        dataService: widget.dataService,
                        vehicleId: widget.vehicle.id,
                        transactionId: transactionId,
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Recharge EV Charging Card',
                          style: TextStyle(
                            color: AppTheme.navy,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _CardValue(
                    label: 'Current balance',
                    value: _formatMoney(currentBalance, 'INR'),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Select amount',
                    style: TextStyle(
                      color: AppTheme.navy,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final amount in _presetAmounts)
                        ChoiceChip(
                          label: Text('₹${amount.toStringAsFixed(0)}'),
                          selected: _selectedAmount == amount,
                          onSelected: _processing
                              ? null
                              : (_) => setState(() => _selectedAmount = amount),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    initialValue: _selectedAmount.toStringAsFixed(2),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Custom amount',
                      prefixText: '₹ ',
                    ),
                    onChanged: _processing
                        ? null
                        : (value) {
                            final parsed = double.tryParse(value);
                            if (parsed != null && parsed > 0) {
                              setState(() => _selectedAmount = parsed);
                            }
                          },
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F6F9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Payment summary',
                          style: TextStyle(
                            color: AppTheme.navy,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Expanded(
                              child: Text('Charging Card Recharge'),
                            ),
                            Text(_formatMoney(_selectedAmount, 'INR')),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Expanded(
                              child: Text('PayPal Sandbox Amount'),
                            ),
                            Text('${_formatMoney(paypalAmount, 'USD')} USD'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Expanded(child: Text('Provider')),
                            const Text('PayPal Sandbox'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Expanded(child: Text('Conversion')),
                            Text(
                              'Demo fixed rate (DEMO ONLY): '
                              '₹1 = \$${_demoExchangeRateInrToUsd.toStringAsFixed(3)}',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_orderId != null &&
                      !kIsWeb &&
                      _approvalUrl != null &&
                      _approvalUrl!.isNotEmpty) ...[
                    Text(
                      'External PayPal approval (Android/iOS): complete the '
                      'checkout, return here, and confirm capture.',
                      style: const TextStyle(color: AppTheme.mutedBlue),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _statusMessage!,
                      style: const TextStyle(color: AppTheme.mutedBlue),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (_orderId == null) ...[
                    FilledButton.icon(
                      onPressed: _processing ? null : _createOrder,
                      icon: const Icon(Icons.lock_open_rounded),
                      label: _processing
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Continue to PayPal'),
                    ),
                  ] else if (kIsWeb) ...[
                    FilledButton.icon(
                      onPressed: _processing
                          ? null
                          : _webCheckoutReady
                          ? _startWebCheckout
                          : _prepareWebCheckout,
                      icon: const Icon(Icons.payments_rounded),
                      label: _processing
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _webCheckoutReady
                                  ? 'Pay with PayPal'
                                  : 'Prepare PayPal checkout',
                            ),
                    ),
                  ] else ...[
                    FilledButton.icon(
                      onPressed: _processing ? null : _captureApprovedOrder,
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      label: _processing
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Confirm payment capture'),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _processing
                          ? null
                          : () async {
                              final uri = Uri.tryParse(_approvalUrl ?? '');
                              if (uri != null &&
                                  uri.scheme == 'https' &&
                                  (uri.host == 'sandbox.paypal.com' ||
                                      uri.host.endsWith(
                                        '.sandbox.paypal.com',
                                      )) &&
                                  mounted) {
                                final opened = await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );
                                if (!opened) {
                                  _showError(
                                    'Could not open PayPal Sandbox checkout.',
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open PayPal checkout'),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RecentTransactionSummary extends StatelessWidget {
  const _RecentTransactionSummary({
    required this.uid,
    required this.vehicleId,
    required this.dataService,
  });

  final String uid;
  final String vehicleId;
  final DataService dataService;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ChargingTransaction>>(
      stream: dataService.watchChargingTransactions(uid, vehicleId: vehicleId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _CardMessage(
            icon: Icons.cloud_off_rounded,
            message: 'Recent transaction data could not be loaded.',
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const LinearProgressIndicator();
        }
        final transactions = snapshot.data ?? const [];
        if (transactions.isEmpty) {
          return const _CardMessage(
            icon: Icons.receipt_long_rounded,
            message: 'No transactions yet.',
          );
        }
        final transaction = transactions.first;
        return _TransactionTile(
          transaction: transaction,
          dataService: dataService,
        );
      },
    );
  }
}

class _ChargingCardVisual extends StatelessWidget {
  const _ChargingCardVisual({required this.card});

  final ChargingCard card;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF12395A), Color(0xFF167A92)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: AppTheme.navy.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, color: Colors.white, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  card.cardType ?? 'Charging Card',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.contactless_rounded, color: Colors.white70),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            card.displayCardNumber ?? 'Not available',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CARD HOLDER',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      card.cardHolderName ?? 'Not available',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'AVAILABLE BALANCE',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    card.balance == null
                        ? 'Not available'
                        : _formatMoney(card.balance!, card.currency),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardValue extends StatelessWidget {
  const _CardValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.mutedBlue),
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: AppTheme.navy,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardStatus extends StatelessWidget {
  const _CardStatus({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final normalized = value.toLowerCase();
    final color = normalized == 'active'
        ? const Color(0xFF16845B)
        : normalized == 'inactive' || normalized == 'blocked'
        ? const Color(0xFFB44343)
        : AppTheme.mutedBlue;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          const Expanded(
            child: Text('Status', style: TextStyle(color: AppTheme.mutedBlue)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 8, color: color),
                const SizedBox(width: 6),
                Text(
                  value,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CardMessage extends StatelessWidget {
  const _CardMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F9),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.mutedBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.mutedBlue),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionHistory extends StatelessWidget {
  const _TransactionHistory({
    required this.uid,
    required this.vehicleId,
    required this.dataService,
  });

  final String uid;
  final String vehicleId;
  final DataService dataService;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Transaction History',
            style: TextStyle(
              color: AppTheme.navy,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<List<ChargingTransaction>>(
              stream: dataService.watchChargingTransactions(
                uid,
                vehicleId: vehicleId,
              ),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const _CardMessage(
                    icon: Icons.cloud_off_rounded,
                    message:
                        'Transaction history could not be loaded. Check your connection and try again.',
                  );
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final transactions = snapshot.data ?? const [];
                if (transactions.isEmpty) {
                  return const _CardMessage(
                    icon: Icons.receipt_long_rounded,
                    message: 'No transactions yet.',
                  );
                }
                return ListView.separated(
                  itemCount: transactions.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _TransactionTile(
                    transaction: transactions[index],
                    dataService: dataService,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({required this.transaction, this.dataService});

  final ChargingTransaction transaction;
  final DataService? dataService;

  @override
  Widget build(BuildContext context) {
    final amount = transaction.amount;
    final isCredit = transaction.type?.toLowerCase() == 'credit';
    final isDebit = transaction.type?.toLowerCase() == 'debit';
    final timestamp = transaction.date;
    final details = <String>[
      'Date and time: ${timestamp == null ? 'Not available' : '${_dateLabel(timestamp)} · ${_timeLabel(timestamp)}'}',
      'Reference: ${transaction.sessionReferenceId ?? transaction.id}',
      'Card: ${transaction.cardId ?? 'Not available'}',
      'Station: ${transaction.stationName ?? 'Not available'}',
      'Operator: ${transaction.operator ?? 'Not available'}',
      'Vehicle: ${transaction.vehicleId ?? 'Not available'}',
      'Provider: ${transaction.paymentProvider ?? 'Not available'}',
      'Status: ${transaction.status ?? 'Not available'}',
      if (transaction.paypalAmount != null &&
          transaction.paypalCurrency != null &&
          amount != null)
        'Recharge: ${_formatMoney(amount, transaction.currency)}',
      if (transaction.paypalAmount != null &&
          transaction.paypalCurrency != null)
        'PayPal payment: ${_formatMoney(transaction.paypalAmount!, transaction.paypalCurrency)} ${transaction.paypalCurrency}',
      if (transaction.conversionType == 'demo_fixed_rate' &&
          transaction.demoExchangeRate != null)
        'Conversion: Demo fixed rate (DEMO ONLY), '
            '₹1 = \$${transaction.demoExchangeRate!.toStringAsFixed(3)}',
      if (transaction.paypalOrderId != null)
        'PayPal order ID: ${transaction.paypalOrderId}',
      if (transaction.paypalCaptureId != null)
        'PayPal capture ID: ${transaction.paypalCaptureId}',
      'Balance before: ${transaction.balanceBefore == null ? 'Not available' : _formatMoney(transaction.balanceBefore!, transaction.currency)}',
      'Balance after: ${transaction.balanceAfter == null ? 'Not available' : _formatMoney(transaction.balanceAfter!, transaction.currency)}',
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      leading: CircleAvatar(
        backgroundColor: const Color(0xFFEAF2F7),
        child: Icon(
          isCredit ? Icons.south_west_rounded : Icons.north_east_rounded,
          color: AppTheme.blue,
        ),
      ),
      title: Text(
        transaction.description ??
            (transaction.type == null
                ? 'Charging transaction'
                : '${transaction.type![0].toUpperCase()}${transaction.type!.substring(1)}'),
        style: const TextStyle(
          color: AppTheme.navy,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(details.join('\n')),
            // Receipts exist only for PayPal recharges verified by the backend.
            if (isCredit &&
                transaction.paypalCaptureId != null &&
                transaction.vehicleId != null &&
                dataService != null)
              InvoiceDownloadButton(
                dataService: dataService!,
                vehicleId: transaction.vehicleId!,
                transactionId: transaction.id,
                compact: true,
              ),
          ],
        ),
      ),
      isThreeLine: true,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            amount == null
                ? 'Not available'
                : '${isCredit
                      ? '+'
                      : isDebit
                      ? '-'
                      : ''}${_formatMoney(amount, transaction.currency)}',
            style: const TextStyle(
              color: AppTheme.navy,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(transaction.status ?? 'Not available'),
        ],
      ),
    );
  }
}

/// Downloads the payment receipt of a verified recharge.
class InvoiceDownloadButton extends StatefulWidget {
  const InvoiceDownloadButton({
    super.key,
    required this.dataService,
    required this.vehicleId,
    required this.transactionId,
    this.compact = false,
    this.saver = saveInvoicePdf,
  });

  final DataService dataService;
  final String vehicleId;
  final String transactionId;
  final bool compact;
  final InvoiceSaver saver;

  @override
  State<InvoiceDownloadButton> createState() => _InvoiceDownloadButtonState();
}

class _InvoiceDownloadButtonState extends State<InvoiceDownloadButton> {
  bool _loading = false;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (fileName, bytes) = await widget.dataService
          .downloadRechargeInvoice(
            vehicleId: widget.vehicleId,
            transactionId: widget.transactionId,
          );
      await widget.saver(bytes, fileName);
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      debugPrint('Receipt download failed: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : 'The receipt could not be saved. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _loading
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.picture_as_pdf_outlined, size: 18);
    final label = Text(_loading ? 'Preparing receipt…' : 'Download invoice');
    final onPressed = _loading ? null : _download;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      children: [
        if (widget.compact)
          TextButton.icon(onPressed: onPressed, icon: icon, label: label)
        else
          OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label),
        if (_error != null)
          Text(
            _error!,
            textAlign: widget.compact ? TextAlign.start : TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
      ],
    );
  }
}

String _currency(double amount, String currency) {
  final symbol = switch (currency.toUpperCase()) {
    'INR' => '₹',
    'USD' => r'$',
    'EUR' => '€',
    _ => '$currency ',
  };
  return '$symbol${amount.toStringAsFixed(2)}';
}

String _formatMoney(double amount, String? currency) =>
    currency == null || currency.trim().isEmpty
    ? amount.toStringAsFixed(2)
    : _currency(amount, currency);

String _dateLabel(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = value.toLocal();
  return '${date.day.toString().padLeft(2, '0')} '
      '${months[date.month - 1]} ${date.year}';
}

String _timeLabel(DateTime value) {
  final time = value.toLocal();
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
