// edit_profile_screen.dart — edit personal details.
//
// Form for updating the user's profile (name, phone, gender, location, age)
// and notification preference. The avatar is display-only (Google / Firebase
// photo). There is no in-app camera or photo-library upload.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartspoon/features/auth/application/user_provider.dart';
import 'package:smartspoon/features/auth/domain/services/auth_service.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/features/notifications/application/notification_provider.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _locationCtrl;
  late TextEditingController _ageCtrl;

  String? _selectedGender;
  bool _notificationsEnabled = true;
  bool _isLoading = false;

  static const _genders = ['Male', 'Female', 'Non-binary', 'Prefer not to say'];

  @override
  void initState() {
    super.initState();
    final user = Provider.of<UserProvider>(context, listen: false);
    _nameCtrl = TextEditingController(text: user.name ?? '');
    _emailCtrl = TextEditingController(text: user.email ?? '');
    _phoneCtrl = TextEditingController(text: user.phone ?? '');
    _locationCtrl = TextEditingController(text: user.location ?? '');
    _ageCtrl = TextEditingController(text: user.age?.toString() ?? '');
    _selectedGender = _genders.contains(user.gender) ? user.gender : null;
    final notifProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );
    _notificationsEnabled =
        notifProvider.preferences?.enabled ?? user.notificationsEnabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _locationCtrl.dispose();
    _ageCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    try {
      final age = int.tryParse(_ageCtrl.text.trim());
      final updates = <String, dynamic>{
        'name': _nameCtrl.text.trim(),
        'notifications_enabled': _notificationsEnabled,
        if (_phoneCtrl.text.trim().isNotEmpty) 'phone': _phoneCtrl.text.trim(),
        if (_locationCtrl.text.trim().isNotEmpty)
          'location': _locationCtrl.text.trim(),
        'age': ?age,
        if (_selectedGender != null) 'gender': _selectedGender,
      };

      final res = await AuthService.updateProfile(data: updates);

      if (mounted) {
        final u = res['user'] as Map<String, dynamic>?;
        if (u != null) {
          Provider.of<UserProvider>(context, listen: false).setFromMap(u);
        }
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Profile updated!',
              style: GoogleFonts.figtree(color: Colors.white),
            ),
            backgroundColor: AppTheme.sageDeep,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to update: $e',
              style: GoogleFonts.figtree(color: Colors.white),
            ),
            backgroundColor: AppTheme.paprika,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<UserProvider>(
      builder: (context, user, _) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.95,
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(28),
              topRight: Radius.circular(28),
            ),
          ),
          child: Column(
            children: [
              // Drag Handle
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Edit Profile',
                      style: AppTheme.serif(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.close_rounded,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: Theme.of(context).dividerColor.withValues(alpha: 0.12),
              ),

              // Scrollable form
              Expanded(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    24,
                    20,
                    24,
                    20 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── Avatar ─────────────────────────────────────
                        Center(
                          child: CircleAvatar(
                            radius: 44,
                            backgroundColor: AppTheme.caramel.withValues(
                              alpha: 0.12,
                            ),
                            backgroundImage:
                                (user.avatarUrl?.isNotEmpty == true)
                                ? NetworkImage(user.avatarUrl!)
                                : null,
                            child: (user.avatarUrl?.isNotEmpty != true)
                                ? Text(
                                    (user.name?.isNotEmpty == true)
                                        ? user.name![0].toUpperCase()
                                        : '?',
                                    style: AppTheme.serif(
                                      fontSize: 36,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.caramel,
                                    ),
                                  )
                                : null,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Personal Info ───────────────────────────────
                        _sectionLabel('Personal Info'),
                        const SizedBox(height: 12),

                        _buildTextField(
                          label: 'Full Name',
                          ctrl: _nameCtrl,
                          icon: Icons.person_outline_rounded,
                          validator: (v) => (v == null || v.isEmpty)
                              ? 'Name is required'
                              : null,
                        ),
                        const SizedBox(height: 14),

                        _buildTextField(
                          label: 'Email Address',
                          ctrl: _emailCtrl,
                          icon: Icons.email_outlined,
                          enabled: false,
                          hint: 'Managed by sign-in provider',
                        ),
                        const SizedBox(height: 14),

                        _buildTextField(
                          label: 'Phone Number',
                          ctrl: _phoneCtrl,
                          icon: Icons.phone_outlined,
                          keyboardType: TextInputType.phone,
                          hint: 'Optional',
                        ),
                        const SizedBox(height: 28),

                        // ── About You ────────────────────────────────────
                        _sectionLabel('About You'),
                        const SizedBox(height: 12),

                        // Gender dropdown
                        _buildDropdown(
                          label: 'Gender',
                          icon: Icons.wc_outlined,
                          value: _selectedGender,
                          items: _genders,
                          onChanged: (v) => setState(() => _selectedGender = v),
                        ),
                        const SizedBox(height: 14),

                        // Age field
                        _buildTextField(
                          label: 'Age',
                          ctrl: _ageCtrl,
                          icon: Icons.cake_outlined,
                          keyboardType: TextInputType.number,
                          hint: 'Optional',
                          validator: (v) {
                            if (v == null || v.isEmpty) return null;
                            final n = int.tryParse(v);
                            if (n == null || n < 0 || n > 150) {
                              return 'Enter a valid age';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),

                        // Location field
                        _buildTextField(
                          label: 'Location',
                          ctrl: _locationCtrl,
                          icon: Icons.location_on_outlined,
                          hint: 'City or region (optional)',
                          textInputAction: TextInputAction.done,
                        ),
                        const SizedBox(height: 28),

                        // ── Preferences ──────────────────────────────────
                        _sectionLabel('Preferences'),
                        const SizedBox(height: 12),

                        _buildToggleRow(
                          icon: Icons.notifications_outlined,
                          title: 'Push Notifications',
                          subtitle: 'Meal reminders and eating alerts',
                          value: _notificationsEnabled,
                          onChanged: (v) async {
                            setState(() => _notificationsEnabled = v);
                            await Provider.of<NotificationProvider>(
                              context,
                              listen: false,
                            ).toggleAllNotifications(v);
                          },
                        ),
                        const SizedBox(height: 32),

                        // ── Save Button ──────────────────────────────────
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: FilledButton(
                            onPressed: _isLoading ? null : _saveProfile,
                            child: _isLoading
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Save changes'),
                          ),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text.toUpperCase(),
      style: GoogleFonts.figtree(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
        color: AppTheme.caramel,
      ),
    ),
  );

  Widget _buildTextField({
    required String label,
    required TextEditingController ctrl,
    required IconData icon,
    bool enabled = true,
    TextInputType? keyboardType,
    String? hint,
    String? Function(String?)? validator,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return TextFormField(
      controller: ctrl,
      enabled: enabled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      style: GoogleFonts.figtree(
        color: enabled
            ? Theme.of(context).colorScheme.onSurface
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      ),
      decoration: _inputDeco(label: label, icon: icon, hint: hint),
      validator: validator,
    );
  }

  Widget _buildDropdown({
    required String label,
    required IconData icon,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: _inputDeco(label: label, icon: icon),
      dropdownColor: Theme.of(context).colorScheme.surface,
      style: GoogleFonts.figtree(
        color: Theme.of(context).colorScheme.onSurface,
      ),
      hint: Text(
        'Select',
        style: GoogleFonts.figtree(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.35),
        ),
      ),
      items: items
          .map(
            (g) => DropdownMenuItem(
              value: g,
              child: Text(g, style: GoogleFonts.figtree()),
            ),
          )
          .toList(),
      onChanged: onChanged,
    );
  }

  InputDecoration _inputDeco({
    required String label,
    required IconData icon,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: GoogleFonts.figtree(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
      ),
      labelStyle: GoogleFonts.figtree(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
      ),
      prefixIcon: Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
      ),
      filled: true,
      fillColor: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: AppTheme.caramel, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      floatingLabelStyle: GoogleFonts.figtree(
        color: AppTheme.caramel,
        fontSize: 13,
      ),
    );
  }

  Widget _buildToggleRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 22,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.figtree(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.figtree(
                    fontSize: 12,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
