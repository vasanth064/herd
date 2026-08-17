import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class Store {
  static const _profilesKey = 'profiles';
  static const _hostsKey = 'known_hosts';
  static const _themeKey = 'theme_mode';

  final SharedPreferences prefs;
  final FlutterSecureStorage secure;

  Store(this.prefs, this.secure);

  static Future<Store> open() async => Store(
        await SharedPreferences.getInstance(),
        // Defaults to Keystore-backed custom ciphers; the old
        // encryptedSharedPreferences flag is deprecated and ignored.
        const FlutterSecureStorage(aOptions: AndroidOptions()),
      );

  List<Profile> loadProfiles() {
    final raw = prefs.getString(_profilesKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((j) => Profile.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<Profile> profiles) => prefs.setString(
        _profilesKey,
        jsonEncode(profiles.map((p) => p.toJson()).toList()),
      );

  Map<String, String> loadKnownHosts() {
    final raw = prefs.getString(_hostsKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> saveKnownHosts(Map<String, String> hosts) =>
      prefs.setString(_hostsKey, jsonEncode(hosts));

  String? themeMode() => prefs.getString(_themeKey);
  Future<void> setThemeMode(String mode) => prefs.setString(_themeKey, mode);

  Future<String?> secret(String key) => secure.read(key: key);
  Future<void> setSecret(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await secure.delete(key: key);
    } else {
      await secure.write(key: key, value: value);
    }
  }

  Future<void> deleteProfileSecrets(Profile p) async {
    await secure.delete(key: p.secretKey);
    await secure.delete(key: p.passphraseKey);
  }
}
