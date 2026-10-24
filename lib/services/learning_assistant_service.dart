import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vehicle_ble_protocol/vehicle_ble_protocol.dart';

import '../models/vehicle.dart';
import 'api/api_client.dart';

class LearningVehicleContext {
  const LearningVehicleContext({
    required this.vehicle,
    required this.telemetry,
  });

  final Vehicle? vehicle;
  final VehicleControlState? telemetry;

  bool get hasData => vehicle != null || telemetry != null;

  Map<String, Object> toMap() {
    final context = <String, Object>{};
    final vehicleModel = vehicle?.model.trim();
    if (vehicleModel != null && vehicleModel.isNotEmpty) {
      context['vehicleModel'] = vehicleModel;
    }
    final data = telemetry;
    if (data != null) {
      context['batteryPercentage'] = data.batteryPercent;
      context['estimatedRangeKm'] = data.rangeKm;
      context['isCharging'] = data.chargingConnected;
    }
    return context;
  }
}

abstract interface class EvLearningAssistant {
  Future<String> ask(
    String question, {
    required LearningVehicleContext context,
  });
}

class ApiLearningAssistantService implements EvLearningAssistant {
  ApiLearningAssistantService({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  @override
  Future<String> ask(
    String question, {
    required LearningVehicleContext context,
  }) async {
    final normalizedQuestion = question.trim();
    if (normalizedQuestion.isEmpty) {
      throw const LearningAssistantException(
        'Enter a question before asking the EV assistant.',
      );
    }
    if (normalizedQuestion.length > 2000) {
      throw const LearningAssistantException(
        'Please keep your question under 2,000 characters.',
      );
    }

    final contextData = context.toMap();
    final Object? data;
    try {
      data = await _api.post('/v1/assistant/ask', {
        'message': normalizedQuestion,
        'topic': 'EV learning',
        if (contextData.isNotEmpty) 'context': jsonEncode(contextData),
      });
    } on ApiException catch (error) {
      debugPrint('[AI ERROR] Assistant request failed: ${error.code}');
      if (error.statusCode == 400 || error.statusCode == 429) {
        throw LearningAssistantException(error.message);
      }
      if (error.statusCode == 0 ||
          error.code == 'assistant_busy' ||
          error.code == 'assistant_not_configured') {
        throw LearningAssistantException(error.message);
      }
      throw const LearningAssistantException(
        'AI assistant is temporarily unavailable. Please try again.',
      );
    } catch (error) {
      debugPrint('[AI ERROR] Assistant request failed: ${error.runtimeType}');
      throw const LearningAssistantException(
        'AI assistant is temporarily unavailable. Please try again.',
      );
    }

    if (data is! Map || data['success'] != true || data['answer'] is! String) {
      throw const LearningAssistantException(
        'The EV assistant returned an invalid response. Please try again.',
      );
    }
    final answer = (data['answer'] as String).trim();
    if (answer.isEmpty) {
      throw const LearningAssistantException(
        'The EV assistant did not return an answer. Please try again.',
      );
    }
    return answer;
  }
}

class LearningAssistantException implements Exception {
  const LearningAssistantException(this.message);

  final String message;

  @override
  String toString() => message;
}
