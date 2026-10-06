// premium_header.dart — shared top app-bar/header used across main screens.
//
// PremiumHeader shows a greeting/title + subtitle plus optional profile avatar
// (taps to edit-profile) and a notification bell (taps to the notifications
// screen, with an unread badge driven by NotificationProvider). Reads the user
// via UserProvider. Configurable via showProfile/showNotification flags.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/auth/index.dart'; // For UserProvider
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/premium_widgets.dart';
import 'package:smartspoon/features/notifications/application/notification_provider.dart';
import 'package:smartspoon/features/notifications/presentation/screens/notification_screen.dart';
import 'package:smartspoon/features/profile/presentation/screens/edit_profile_screen.dart';

class PremiumHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool showProfile;
  final bool showNotification;

  const PremiumHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.showProfile = true,
    this.showNotification = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Semantics(
            button: showProfile,
            label: showProfile ? 'Edit profile' : null,
            child: GestureDetector(
              onTap: () {
                if (showProfile) {
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (context) => const EditProfileScreen(),
                  );
                }
              },
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  if (showProfile) ...[
                    Consumer<UserProvider>(
                      builder: (context, user, _) {
                        final name = (user.name ?? 'Guest').trim();
                        final initials = name.isNotEmpty
                            ? name
                                  .split(RegExp(r'\s+'))
                                  .where((s) => s.isNotEmpty)
                                  .take(2)
                                  .map((s) => s[0].toUpperCase())
                                  .join()
                            : 'G';
                        final photoUrl = user.avatarUrl;

                        return Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: AppTheme.primaryGradient,
                            boxShadow: [
                              BoxShadow(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.22),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ClipOval(
                            child: photoUrl != null && photoUrl.isNotEmpty
                                ? Image.network(
                                    photoUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (ctx, err, stack) => Center(
                                      child: Text(
                                        initials,
                                        style: AppTheme.serif(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                  )
                                : Center(
                                    child: Text(
                                      initials,
                                      style: AppTheme.serif(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                  ],

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      Consumer<UserProvider>(
                        builder: (context, user, child) {
                          // For time-of-day greetings, replace the title with
                          // the user's actual first name.
                          String displayTitle = title;
                          const greetings = {
                            'Good Morning,',
                            'Good Afternoon,',
                            'Good Evening,',
                          };
                          if (greetings.contains(title)) {
                            final name = (user.name ?? 'Guest').trim();
                            final firstName = name.isNotEmpty
                                ? (name.contains(' ')
                                      ? name.split(RegExp(r'\s+'))[0]
                                      : name)
                                : 'Guest';
                            return Text(
                              firstName,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                            );
                          }
                          return Text(
                            displayTitle,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (showNotification)
            Consumer<NotificationProvider>(
              builder: (context, notificationProvider, child) {
                int unreadCount = 0;
                try {
                  unreadCount = notificationProvider.unreadCount;
                } catch (_) {}

                return Semantics(
                  button: true,
                  label: unreadCount > 0
                      ? 'Notifications, $unreadCount unread'
                      : 'Notifications',
                  child: GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const NotificationScreen(),
                        ),
                      );
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        PremiumIconBox(
                          icon: Icons.notifications_none,
                          color: Theme.of(context).colorScheme.onSurface,
                          size: 24,
                        ),
                        if (unreadCount > 0)
                          Positioned(
                            top: -2,
                            right: -2,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.error,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
