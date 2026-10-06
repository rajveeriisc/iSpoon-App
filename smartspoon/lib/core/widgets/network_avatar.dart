// network_avatar.dart — reusable circular profile-photo widget.
//
// NetworkAvatar renders a user's avatar in a circle of the given radius. It
// resolves relative avatar URLs against AuthService.baseUrl, loads the remote
// image, and falls back to an initial/asset placeholder when no URL is set or
// the image fails to load. Used in the header and profile screens.
import 'package:flutter/material.dart';
import 'package:smartspoon/features/auth/index.dart';

class NetworkAvatar extends StatelessWidget {
  const NetworkAvatar({
    super.key,
    required this.radius,
    this.avatarUrl,
    this.displayName,
    this.fallbackAsset = 'assets/images/ispoon_onboarding.png',
  });

  final double radius;
  final String? avatarUrl;
  final String? displayName;
  final String fallbackAsset;

  @override
  Widget build(BuildContext context) {
    String? url = avatarUrl;
    if (url != null && url.startsWith('/')) {
      url = AuthService.baseUrl + url;
    }

    if (url != null && url.isNotEmpty) {
      return CircleAvatar(radius: radius, backgroundImage: NetworkImage(url));
    }

    final String initial = _extractInitial(displayName);
    if (initial.isNotEmpty) {
      final theme = Theme.of(context);
      final bg = theme.colorScheme.primary.withValues(alpha: 0.15);
      final fg = theme.colorScheme.primary;
      return CircleAvatar(
        radius: radius,
        backgroundColor: bg,
        child: Text(
          initial,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
            fontSize: radius * 0.9,
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundImage: AssetImage(fallbackAsset),
    );
  }

  String _extractInitial(String? name) {
    if (name == null) return '';
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '';
    final first = trimmed.split(RegExp(r'\s+')).first;
    return first.isNotEmpty ? first.characters.first.toUpperCase() : '';
  }
}
