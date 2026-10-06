// user_provider.dart — in-memory current-user profile state.
//
// UserProvider is a ChangeNotifier (provided in main.dart) holding the signed-in
// user's profile fields (id, email, name, phone, gender, location, age,
// avatarUrl) plus a notifications-enabled preference. setFromMap() hydrates it
// from a backend/user JSON map (with defensive type coercion) and notifies
// listeners so headers, profile, and edit screens rebuild when the profile
// changes. Pure UI state — no persistence or network here.
import 'package:flutter/foundation.dart';

class UserProvider with ChangeNotifier {
  int? id;
  String? email;
  String? name;
  String? phone;
  String? gender;
  String? location;
  int? age;
  String? avatarUrl;

  bool? _notificationsEnabled;
  bool? get notificationsEnabled => _notificationsEnabled;
  set notificationsEnabled(bool? value) {
    if (_notificationsEnabled == value) return;
    _notificationsEnabled = value;
    notifyListeners();
  }

  void setFromMap(Map<String, dynamic> user) {
    final rawId = user['id'];
    id = rawId is num ? rawId.toInt() : int.tryParse(rawId?.toString() ?? '');
    email = user['email'] as String?;
    name = user['name'] as String?;
    phone = user['phone'] as String?;
    gender = user['gender'] as String?;
    location = user['location'] as String?;
    final rawAge = user['age'];
    age = rawAge is num
        ? rawAge.toInt()
        : int.tryParse(rawAge?.toString() ?? '');
    final rawNotifications = user['notifications_enabled'];
    _notificationsEnabled = rawNotifications is bool
        ? rawNotifications
        : rawNotifications == null
            ? null
            : rawNotifications.toString().toLowerCase() == 'true';
    avatarUrl = user['avatar_url'] as String?;
    notifyListeners();
  }

  void clear() {
    id = null;
    email = null;
    name = null;
    phone = null;
    gender = null;
    location = null;
    age = null;
    _notificationsEnabled = null;
    avatarUrl = null;
    notifyListeners();
  }
}
