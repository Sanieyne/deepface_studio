import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../features/cloud_mode/data/models/saved_generation.dart';
import 'api_client.dart';

/// High-level authentication state for the app-wide login gate.
enum AuthStatus {
  /// Initial state: stored session not checked yet.
  unknown,

  /// A session is active (tokens stored, user may still be loading).
  authenticated,

  /// No usable session: login screen must be shown.
  unauthenticated,
}

/// Typed failure for register/login/refresh flows.
///
/// Carries the human-readable server message (validation details included)
/// so screens can display it inline without parsing HTTP responses.
class AuthException implements Exception {
  final String message;
  final int? statusCode;

  AuthException(this.message, [this.statusCode]);

  @override
  String toString() => 'AuthException: $message';
}

/// Minimal secure key-value store abstraction.
///
/// Production uses the OS credential store via [FlutterSecureTokenStore]
/// (Keychain on macOS, Credential Manager on Windows, libsecret on Linux).
/// Tests inject [InMemoryTokenStore]. JWTs must never live in plain SQLite.
abstract class SecureTokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();
}

/// [SecureTokenStore] backed by flutter_secure_storage with automatic
/// fallback for Linux/headless environments lacking a Secret Service (gnome-keyring).
class FlutterSecureTokenStore implements SecureTokenStore {
  final FlutterSecureStorage _storage;
  final Map<String, String> _memoryFallback = {};
  bool _useFallback = false;

  FlutterSecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  File? _getFallbackFile(String key) {
    try {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '.';
      final dir = Directory('$home/.config/ai_image_studio');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return File('${dir.path}/.$key.session');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> read(String key) async {
    if (_useFallback) {
      if (_memoryFallback.containsKey(key)) return _memoryFallback[key];
      final file = _getFallbackFile(key);
      if (file != null && await file.exists()) {
        try {
          final content = await file.readAsString();
          return utf8.decode(base64Decode(content));
        } catch (_) {}
      }
      return null;
    }

    try {
      final val = await _storage.read(key: key);
      if (val != null) return val;
    } catch (e) {
      debugPrint('[FlutterSecureTokenStore] secure read failed ($e), using local fallback store');
      _useFallback = true;
    }

    if (_memoryFallback.containsKey(key)) return _memoryFallback[key];
    final file = _getFallbackFile(key);
    if (file != null && await file.exists()) {
      try {
        final content = await file.readAsString();
        return utf8.decode(base64Decode(content));
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<void> write(String key, String value) async {
    _memoryFallback[key] = value;
    if (!_useFallback) {
      try {
        await _storage.write(key: key, value: value);
        return;
      } catch (e) {
        debugPrint(
          '[FlutterSecureTokenStore] Keyring/libsecret unavailable ($e). '
          'Falling back to secure local configuration file.',
        );
        _useFallback = true;
      }
    }

    try {
      final file = _getFallbackFile(key);
      if (file != null) {
        await file.writeAsString(base64Encode(utf8.encode(value)));
        try {
          if (!Platform.isWindows) {
            Process.runSync('chmod', ['600', file.path]);
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[FlutterSecureTokenStore] fallback file write failed ($e), keeping token in memory');
    }
  }

  @override
  Future<void> delete(String key) async {
    _memoryFallback.remove(key);
    try {
      await _storage.delete(key: key);
    } catch (_) {}
    try {
      final file = _getFallbackFile(key);
      if (file != null && await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  @override
  Future<void> deleteAll() async {
    _memoryFallback.clear();
    try {
      await _storage.deleteAll();
    } catch (_) {}
    for (final key in [AuthService.accessTokenKey, AuthService.refreshTokenKey]) {
      try {
        final file = _getFallbackFile(key);
        if (file != null && await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }
}

/// Non-persistent [SecureTokenStore] for unit/widget tests.
@visibleForTesting
class InMemoryTokenStore implements SecureTokenStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _values.clear();
  }
}

/// App-wide authentication service.
///
/// Singleton [ChangeNotifier], consistent with this codebase's existing
/// convention (singleton services + `StatefulWidget`/`setState`, no
/// Provider/Riverpod/Bloc). UI observes it with `AnimatedBuilder` or
/// `addListener`.
///
/// Talks to `POST $baseUrl/auth/register`, `POST $baseUrl/auth/login` and
/// `POST $baseUrl/auth/refresh`. Successful responses share the shape
/// `{success, message, data: {user, accessToken, refreshToken}}`, except
/// refresh which returns `{accessToken, refreshToken}` without `user`.
class AuthService extends ChangeNotifier {
  static const String accessTokenKey = 'lumina.access_token';
  static const String refreshTokenKey = 'lumina.refresh_token';
  static const Duration requestTimeout = Duration(seconds: 25);

  static final AuthService instance = AuthService._();

  final http.Client _http;
  final SecureTokenStore _store;
  final String baseUrl;

  AuthService._({
    http.Client? httpClient,
    SecureTokenStore? tokenStore,
    String? baseUrl,
  })  : _http = httpClient ?? http.Client(),
        _store = tokenStore ?? FlutterSecureTokenStore(),
        baseUrl = baseUrl ?? kCloudApiBaseUrl;

  /// Creates an isolated service for tests (never touches the singleton).
  @visibleForTesting
  factory AuthService.forTest({
    required http.Client httpClient,
    required SecureTokenStore tokenStore,
    String? baseUrl,
  }) {
    return AuthService._(
      httpClient: httpClient,
      tokenStore: tokenStore,
      baseUrl: baseUrl,
    );
  }

  AuthStatus _status = AuthStatus.unknown;
  CloudUserProfile? _user;
  String? _accessToken;
  String? _refreshToken;

  Future<void>? _initFuture;
  Future<bool>? _inflightRefresh;

  /// Current auth state. Starts as [AuthStatus.unknown] until [init] or
  /// [restoreSession] resolves the stored session.
  AuthStatus get status => _status;

  /// Synchronous session check for UI gates. Only meaningful after [init].
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  /// Cached profile of the signed-in user, null when logged out.
  CloudUserProfile? get currentUser => _user;

  /// In-memory access token (mirrors secure storage after [init]).
  String? get accessToken => _accessToken;

  /// Loads cached tokens from secure storage (idempotent, no network).
  Future<void> init() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    try {
      _accessToken = await _store.read(accessTokenKey);
      _refreshToken = await _store.read(refreshTokenKey);
    } catch (e) {
      debugPrint('[AuthService] secure storage read failed: $e');
      _accessToken = null;
      _refreshToken = null;
    }
    _setStatus(
      _refreshToken != null && _refreshToken!.isNotEmpty
          ? AuthStatus.authenticated
          : AuthStatus.unauthenticated,
    );
  }

  /// Whether a session exists. Ensures [init] ran first.
  Future<bool> isLoggedIn() async {
    await init();
    return _status == AuthStatus.authenticated;
  }

  /// Validates the stored session on app launch.
  ///
  /// Attempts a silent token refresh (tokens may have expired while the app
  /// was closed) and loads the user profile. Returns true when the app may
  /// proceed to [HomeScreen], false when the login screen must be shown.
  ///
  /// If the device is offline but tokens are stored, enters optimistically:
  /// local generation stays usable and API calls retry/refresh when online.
  Future<bool> restoreSession() async {
    await init();
    if (_refreshToken == null || _refreshToken!.isEmpty) {
      _setStatus(AuthStatus.unauthenticated);
      return false;
    }
    final refreshed = await refreshTokens();
    if (!refreshed) {
      // refreshTokens() already logged out on 401 (expired/invalid token).
      if (_status == AuthStatus.unauthenticated) return false;
      // Network failure: stay optimistically logged in while offline.
      _setStatus(AuthStatus.authenticated);
      return true;
    }
    try {
      await getCurrentUser();
    } catch (_) {
      // Profile load is best-effort here; tokens are valid regardless.
    }
    _setStatus(AuthStatus.authenticated);
    return true;
  }

  /// Registers a new account and starts a session.
  ///
  /// Throws [AuthException] with the server message on any failure
  /// (validation errors, duplicate email/username, network failure).
  Future<CloudUserProfile> register(
    String username,
    String email,
    String password,
  ) async {
    late http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('$baseUrl/auth/register'),
            // Header, not body: backends before device sessions reject unknown body fields.
            headers: {'Content-Type': 'application/json', 'X-Device-Label': deviceLabel},
            body: jsonEncode({
              'username': username.trim(),
              'email': email.trim(),
              'password': password,
            }),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw AuthException('Request timed out. Check your connection.');
    } catch (e) {
      throw AuthException(_networkMessage(e));
    }
    return _handleSessionResponse(res);
  }

  /// Signs in with email + password and starts a session.
  ///
  /// Throws [AuthException] with the server message on any failure
  /// (invalid credentials, deactivated account, network failure).
  Future<CloudUserProfile> login(String email, String password) async {
    late http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('$baseUrl/auth/login'),
            headers: {'Content-Type': 'application/json', 'X-Device-Label': deviceLabel},
            body: jsonEncode({
              'email': email.trim(),
              'password': password,
            }),
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw AuthException('Request timed out. Check your connection.');
    } catch (e) {
      throw AuthException(_networkMessage(e));
    }
    return _handleSessionResponse(res);
  }

  /// Rotates the token pair using the stored refresh token.
  ///
  /// Concurrent callers share a single in-flight request. Returns true on
  /// success. On 401/403 (expired, invalid, or reused refresh token) the
  /// session is destroyed via [logout] and false is returned. Network
  /// failures return false without touching the session.
  Future<bool> refreshTokens() {
    if (_inflightRefresh != null) return _inflightRefresh!;
    final future = _doRefresh();
    _inflightRefresh = future;
    future.whenComplete(() => _inflightRefresh = null);
    return future;
  }

  Future<bool> _doRefresh() async {
    await init();
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      await logout();
      return false;
    }
    late http.Response res;
    try {
      res = await _http
          .post(
            Uri.parse('$baseUrl/auth/refresh'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'refreshToken': refreshToken}),
          )
          .timeout(requestTimeout);
    } catch (e) {
      debugPrint('[AuthService] refresh network failure: $e');
      return false;
    }
    if (res.statusCode == 200) {
      try {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final data = body['data'] as Map<String, dynamic>?;
        final newAccess = data?['accessToken'] as String?;
        final newRefresh = data?['refreshToken'] as String?;
        if (newAccess == null ||
            newAccess.isEmpty ||
            newRefresh == null ||
            newRefresh.isEmpty) {
          debugPrint('[AuthService] refresh response missing tokens');
          await logout();
          return false;
        }
        await _persistTokens(access: newAccess, refresh: newRefresh);
        // NOTE: refresh responses carry no `user` object; the in-memory
        // profile from login/register is intentionally preserved.
        _setStatus(AuthStatus.authenticated);
        return true;
      } catch (e) {
        debugPrint('[AuthService] refresh parse failure: $e');
        await logout();
        return false;
      }
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      await logout();
      return false;
    }
    debugPrint('[AuthService] refresh failed: HTTP ${res.statusCode}');
    return false;
  }

  /// Returns the cached profile, fetching `GET /users/me` when needed or when [forceRefresh] is true.
  ///
  /// Returns null when logged out. Retries once after a silent refresh on
  /// 401 (the access token may have expired mid-session).
  Future<CloudUserProfile?> getCurrentUser({bool forceRefresh = false}) async {
    if (_user != null && !forceRefresh) return _user;
    await init();
    if (_accessToken == null || _accessToken!.isEmpty) return null;
    var res = await _fetchProfile(_accessToken!);
    if (res == null) return null; // network failure; keep session.
    if (res.statusCode == 401) {
      final refreshed = await refreshTokens();
      if (!refreshed) return null;
      res = await _fetchProfile(_accessToken!);
      if (res == null) return null;
    }
    if (res.statusCode == 200) {
      try {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final data = body['data'] as Map<String, dynamic>?;
        if (data != null) {
          _user = CloudUserProfile.fromJson(data);
          notifyListeners();
          return _user;
        }
      } catch (e) {
        debugPrint('[AuthService] profile parse failure: $e');
      }
    }
    return null;
  }

  Future<http.Response?> _fetchProfile(String token) async {
    try {
      return await _http
          .get(
            Uri.parse('$baseUrl/users/me'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(requestTimeout);
    } catch (e) {
      debugPrint('[AuthService] profile fetch failed: $e');
      return null;
    }
  }

  /// Label for this device in the user's session list, e.g. "Windows app".
  static String get deviceLabel {
    if (kIsWeb) return 'Web app';
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'Windows app';
      case TargetPlatform.macOS:
        return 'macOS app';
      case TargetPlatform.linux:
        return 'Linux app';
      case TargetPlatform.android:
        return 'Android app';
      case TargetPlatform.iOS:
        return 'iOS app';
      case TargetPlatform.fuchsia:
        return 'Fuchsia app';
    }
  }

  /// Timeout for the best-effort server logout in [signOut].
  static const Duration signOutTimeout = Duration(seconds: 5);

  /// User-initiated sign out: ends this device's session on the server
  /// (POST /auth/logout), then clears the local session. The local session is
  /// always cleared, even when the server can't be reached.
  Future<void> signOut() async {
    await init();
    final refreshToken = _refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        final res = await _http
            .post(
              Uri.parse('$baseUrl/auth/logout'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'refreshToken': refreshToken}),
            )
            .timeout(signOutTimeout);
        if (res.statusCode != 200) {
          debugPrint('[AuthService] server logout: HTTP ${res.statusCode}');
        }
      } catch (e) {
        debugPrint('[AuthService] server logout failed (signing out locally): $e');
      }
    }
    await logout();
  }

  /// Destroys the local session: clears secure storage and in-memory state.
  /// Used when the session is already invalid; for a user's Sign Out, use [signOut].
  Future<void> logout() async {
    _user = null;
    _accessToken = null;
    _refreshToken = null;
    try {
      await _store.delete(accessTokenKey);
      await _store.delete(refreshTokenKey);
    } catch (e) {
      debugPrint('[AuthService] secure storage clear failed: $e');
    }
    _setStatus(AuthStatus.unauthenticated);
  }

  /// One-time migration for tokens stored by older app versions in plain
  /// SQLite (`cloud_auth_token`). The access token is adopted into secure
  /// storage; callers must delete the SQLite copy afterwards.
  ///
  /// No-op when secure storage already holds a session.
  Future<void> adoptLegacyAccessToken(String token) async {
    await init();
    final hasSession = (_refreshToken != null && _refreshToken!.isNotEmpty) ||
        (_accessToken != null && _accessToken!.isNotEmpty);
    if (hasSession || token.isEmpty) return;
    _accessToken = token;
    try {
      await _store.write(accessTokenKey, token);
    } catch (e) {
      debugPrint('[AuthService] legacy token migration failed: $e');
    }
    // Optimistic: no refresh token exists, so the first 401 will log out
    // and route to login. Still better than stranding the session.
    _setStatus(AuthStatus.authenticated);
  }

  /// Updates the cached profile (e.g. after a profile edit elsewhere).
  void updateCachedUser(CloudUserProfile user) {
    _user = user;
    notifyListeners();
  }

  /// Force-refreshes the latest profile and credits balance from GET /users/me.
  Future<CloudUserProfile?> refreshProfile() async {
    return getCurrentUser(forceRefresh: true);
  }

  /// Explicitly terminates the session and triggers a clean redirect to login.
  /// Called by transports (REST ApiClient, WebSocket clients) when authentication
  /// is expired/invalid and cannot be refreshed.
  Future<void> handleSessionExpired() async {
    debugPrint('[AuthService] Session expired. Terminating session and redirecting to login.');
    await logout();
  }

  Future<CloudUserProfile> _handleSessionResponse(http.Response res) async {
    if (res.statusCode == 200 || res.statusCode == 201) {
      try {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final data = body['data'] as Map<String, dynamic>?;
        final userJson = data?['user'] as Map<String, dynamic>?;
        final access = data?['accessToken'] as String?;
        final refresh = data?['refreshToken'] as String?;
        if (userJson == null ||
            access == null ||
            access.isEmpty ||
            refresh == null ||
            refresh.isEmpty) {
          throw AuthException('Unexpected server response. Try again.');
        }
        await _persistTokens(access: access, refresh: refresh);
        _user = CloudUserProfile.fromJson(userJson);
        _setStatus(AuthStatus.authenticated);
        return _user!;
      } catch (e) {
        if (e is AuthException) rethrow;
        throw AuthException('Unexpected server response. Try again.');
      }
    }
    throw AuthException(_errorMessage(res), res.statusCode);
  }

  Future<void> _persistTokens({
    required String access,
    required String refresh,
  }) async {
    _accessToken = access;
    _refreshToken = refresh;
    try {
      await _store.write(accessTokenKey, access);
      await _store.write(refreshTokenKey, refresh);
    } catch (e) {
      debugPrint('[AuthService] warning: secure storage write failed ($e), keeping active session in memory.');
    }
  }

  void _setStatus(AuthStatus status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }

  /// Extracts `message` (+ `errors[]`) from `{success:false,...}` bodies.
  static String _errorMessage(http.Response res) {
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final message = body['message'] as String?;
      final errors = body['errors'] as List?;
      final detail = errors != null && errors.isNotEmpty
          ? errors.map((e) => e.toString()).join(' ')
          : '';
      if (message != null && message.isNotEmpty) {
        return detail.isNotEmpty ? '$message: $detail' : message;
      }
    } catch (_) {}
    return 'Request failed (HTTP ${res.statusCode}). Try again.';
  }

  static String _networkMessage(Object e) {
    if (e is http.ClientException) {
      return 'Could not reach the server. Check your connection.';
    }
    return 'Network error: ${_shortError(e)}';
  }

  static String _shortError(Object e) {
    final text = e.toString();
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }
}
