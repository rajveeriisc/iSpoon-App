// ai_lab_page.dart — AI Lab tab: live meal, coach, steadiness and eating
// pattern, all from the on-phone eating model (AiLabService).
import 'package:flutter/material.dart';
import 'package:smartspoon/features/ai_lab/domain/services/ai_lab_service.dart';
import 'package:smartspoon/features/ai_lab/presentation/widgets/ai_lab_view.dart';

class AiLabPage extends StatefulWidget {
  const AiLabPage({super.key});

  @override
  State<AiLabPage> createState() => _AiLabPageState();
}

class _AiLabPageState extends State<AiLabPage> {
  final AiLabService _service = AiLabService();

  @override
  void initState() {
    super.initState();
    // Normally already running (main.dart, before any page opens); idempotent.
    _service.start();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _service,
        builder: (context, _) => AiLabView(data: _service.view, actions: _service),
      );
}
