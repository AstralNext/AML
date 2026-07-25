import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/features/java/application/java_download_service.dart';
import 'package:aml/src/features/settings/application/java_settings_state.dart';
import 'package:aml/src/features/settings/ui/widgets/java_selector.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class JavaSettingsPage extends StatefulWidget {
	const JavaSettingsPage({super.key});

	@override
	State<JavaSettingsPage> createState() => _JavaSettingsPageState();
}

class _JavaSettingsPageState extends State<JavaSettingsPage> {
	late final JavaSettingsState _javaSettings = getIt<JavaSettingsState>();
	late final JavaDownloadService _javaDownloadService =
		getIt<JavaDownloadService>();
	late final RuntimeState _runtimeState = getIt<RuntimeState>();

	static const _versions = [25, 21, 17, 8];

	@override
	Widget build(BuildContext context) {
		return ListView(
			padding: const EdgeInsets.fromLTRB(16, 10, 24, 10),
			children: [
				for (var index = 0; index < _versions.length; index++)
					_buildVersionSection(
						context,
						version: _versions[index],
						addTopSpacing: index != 0,
					),
			],
		);
	}

	Widget _buildVersionSection(
		BuildContext context, {
		required int version,
		required bool addTopSpacing,
	}) {
		final tokens = context.tokens;

		return Padding(
			padding: EdgeInsets.only(top: addTopSpacing ? 16 : 0, bottom: 8),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					Text(
						'Java $version 路径',
						style: TextStyle(
							fontSize: 18,
							fontWeight: FontWeight.w600,
							color: tokens.colorContrast,
						),
					),
					const SizedBox(height: 10),
					Watch(
						(_) {
							final path = _javaSettings
								.pathSignalForMajor(version)
								.watch(context);
							return JavaSelector(
								version: version,
								path: path,
								javaDownloadService: _javaDownloadService,
								appDataDir: _runtimeState.appDataDirectory.value,
								onPathChanged: (value) =>
									_javaSettings.setPathForMajor(version, value),
							);
						},
					),
				],
			),
		);
	}
}
