import 'package:aml/src/features/home/ui/home_featured_section.dart';
import 'package:aml/src/features/home/ui/home_greeting_section.dart';
import 'package:aml/src/features/home/ui/home_helpers.dart';
import 'package:aml/src/features/home/ui/home_jump_back_section.dart';
import 'package:aml/src/features/home/ui/home_onboarding.dart';
import 'package:flutter/material.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _jumpLoading = true;
  HomeJumpItem? _firstJump;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  HomeGreetingSection(
                    jumpLoading: _jumpLoading,
                    firstJump: _firstJump,
                  ),
                  const SizedBox(height: 12),
                  const HomeOnboarding(),
                  const SizedBox(height: 6),
                  HomeJumpBackSection(
                    onSummaryChanged: (jumpLoading, firstJump) {
                      setState(() {
                        _jumpLoading = jumpLoading;
                        _firstJump = firstJump;
                      });
                    },
                  ),
                  const SizedBox(height: 22),
                  const HomeFeaturedSection(),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
