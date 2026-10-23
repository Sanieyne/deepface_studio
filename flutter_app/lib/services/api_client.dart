import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Single source of truth for the cloud backend base URL.
///
/// `CloudApiService.baseUrl` defaults to this; tests override per-service.
const String kCloudApiBaseUrl = 'https://cosmic-gen.com/ai-api/api/v1';

/// Authenticated HTTP wrapper for protected backend calls.
///
/// Attaches `Authorization: Bearer <accessToken>` from [AuthService] and
/// implements the standard 401 recovery path: on the first 401 it performs
/// one silent [AuthService.refreshTokens] and retries the original request
/// once. If the refresh fails (expired/invalid refresh token),
/// [AuthService] has already logged out, which flips [AuthStatus] to
/// unauthenticated — the app's login gate observes that and redirects to
/// the login screen. No extra callback plumbing is needed.
///
/// Access tokens expire after 15 minutes, so this path runs routinely;
/// concurrent 401s share one in-flight refresh inside [AuthService].
class ApiClient {
  final AuthService _auth;
  final http.Client _http;
  final Duration timeout;

  /// Test-only override of the base URL (production uses [kCloudApiBaseUrl]).
  final String baseUrl;

  ApiClient({
    AuthService? authService,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
    String? baseUrl,
  })  : _auth = authService ?? AuthService.instance,
        _http = httpClient ?? http.Client(),
        baseUrl = baseUrl ?? kCloudApiBaseUrl;

  Future<http.Response> get(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    bool auth = true,
    Duration? timeout,
  }) {
    return _send(
      'GET',
      _uri(path, queryParameters),
      headers: headers,
      auth: auth,
      timeout: timeout ?? this.timeout,
    );
  }

  Future<http.Response> post(
    String path, {
    Map<String, dynamic>? jsonBody,
    Map<String, String>? headers,
    bool auth = true,
    Duration? timeout,
  }) {
    return _send(
      'POST',
      _uri(path, null),
      headers: headers,
      body: jsonBody == null ? null : jsonEncode(jsonBody),
      auth: auth,
      timeout: timeout ?? this.timeout,
    );
  }

  Future<http.Response> patch(
    String path, {
    Map<String, dynamic>? jsonBody,
    Map<String, String>? headers,
    bool auth = true,
    Duration? timeout,
  }) {
    return _send(
      'PATCH',
      _uri(path, null),
      headers: headers,
      body: jsonBody == null ? null : jsonEncode(jsonBody),
      auth: auth,
      timeout: timeout ?? this.timeout,
    );
  }

  Future<http.Response> delete(
    String path, {
    Map<String, String>? headers,
    bool auth = true,
    Duration? timeout,
  }) {
    return _send(
      'DELETE',
      _uri(path, null),
      headers: headers,
      auth: auth,
      timeout: timeout ?? this.timeout,
    );
  }

  Uri _uri(String path, Map<String, String>? queryParameters) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$normalized')
        .replace(queryParameters: queryParameters?.isEmpty ?? true
            ? null
            : queryParameters);
  }

  Map<String, String> _headers(Map<String, String>? extra, {bool auth = true}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (extra != null) headers.addAll(extra);
    if (auth) {
      final token = _auth.accessToken;
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    bool auth = true,
    required Duration timeout,
  }) async {
    Future<http.Response> dispatch() {
      final h = _headers(headers, auth: auth);
      switch (method) {
        case 'POST':
          return _http.post(uri, headers: h, body: body).timeout(timeout);
        case 'PATCH':
          return _http.patch(uri, headers: h, body: body).timeout(timeout);
        case 'DELETE':
          return _http.delete(uri, headers: h).timeout(timeout);
        case 'GET':
        default:
          return _http.get(uri, headers: h).timeout(timeout);
      }
    }

    var res = await dispatch();
    if (res.statusCode == 401 && auth) {
      // Exactly one silent refresh + one retry. Concurrent 401s across
      // parallel requests collapse into a single refresh call.
      final refreshed = await _auth.refreshTokens();
      if (refreshed) {
        res = await dispatch();
      } else {
        debugPrint(
          '[ApiClient] $method $uri still 401 after refresh; '
          'session ended, UI gate will redirect to login.',
        );
      }
    }
    return res;
  }
}
