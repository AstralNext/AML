import 'package:aml/src/features/java/application/java_download_service.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class JavaDetectionDialog extends StatefulWidget {
	const JavaDetectionDialog({
		super.key,
		required this.version,
		required this.currentPath,
		required this.javaDownloadService,
		this.appDataDir,
	});

	final int version;
	final String currentPath;
	final JavaDownloadService javaDownloadService;
	final String? appDataDir;

	static Future<JavaRuntimeVersion?> show(
		BuildContext context, {
		required int version,
		required String currentPath,
		required JavaDownloadService javaDownloadService,
		String? appDataDir,
	}) {
		return showDialog<JavaRuntimeVersion>(
			context: context,
			builder: (_) => JavaDetectionDialog(
				version: version,
				currentPath: currentPath,
				javaDownloadService: javaDownloadService,
				appDataDir: appDataDir,
			),
		);
	}

	@override
	State<JavaDetectionDialog> createState() => _JavaDetectionDialogState();
}

class _JavaDetectionDialogState extends State<JavaDetectionDialog> {
	List<JavaRuntimeVersion> _installations = [];
	bool _loading = true;

	@override
	void initState() {
		super.initState();
		_loadInstallations();
	}

	Future<void> _loadInstallations() async {
		final results = await widget.javaDownloadService.findFilteredJres(
			widget.version,
			appDataDir: widget.appDataDir,
		);
		if (!mounted) return;
		setState(() {
			_installations = results;
			_loading = false;
		});
	}

	void _select(JavaRuntimeVersion installation) {
		Navigator.of(context).pop(installation);
	}

	@override
	Widget build(BuildContext context) {
		final tokens = context.tokens;

		return Dialog(
			backgroundColor: tokens.colorBg,
			shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
			child: ConstrainedBox(
				constraints: const BoxConstraints(maxWidth: 720, maxHeight: 480),
				child: Padding(
					padding: const EdgeInsets.all(16),
					child: Column(
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Text(
								'选择 Java 版本',
								style: TextStyle(
									fontSize: 18,
									fontWeight: FontWeight.w700,
									color: tokens.colorContrast,
								),
							),
							const SizedBox(height: 12),
							Expanded(
								child: _loading
									? const Center(child: CircularProgressIndicator())
									: _installations.isEmpty
										? Center(
											child: Text(
												'未找到 Java ${widget.version} 安装',
												style: TextStyle(
													color: tokens.colorBase.withValues(alpha: 0.7),
												),
											),
										)
										: ListView.separated(
											itemCount: _installations.length,
											separatorBuilder: (_, __) => const SizedBox(height: 8),
											itemBuilder: (context, index) {
												final installation = _installations[index];
												final isSelected =
													installation.path == widget.currentPath;

												return Container(
													padding: const EdgeInsets.symmetric(
														horizontal: 12,
														vertical: 10,
													),
													decoration: BoxDecoration(
														color: tokens.colorBg.withValues(alpha: 0.5),
														borderRadius: BorderRadius.circular(8),
														border: Border.all(
															color: tokens.colorSecondary.withValues(
																alpha: 0.25,
															),
														),
													),
													child: Row(
														children: [
															SizedBox(
																width: 72,
																child: Text(
																	installation.version,
																	style: TextStyle(
																		fontWeight: FontWeight.w700,
																		color: tokens.colorBrand,
																	),
																),
															),
															Expanded(
																child: Text(
																	installation.path,
																	maxLines: 2,
																	overflow: TextOverflow.ellipsis,
																	style: TextStyle(
																		fontFamily: 'monospace',
																		fontSize: 12,
																		color: tokens.colorBase.withValues(
																			alpha: 0.85,
																		),
																	),
																),
															),
															const SizedBox(width: 8),
															if (isSelected)
																NavRectButton(
																	text: '已选择',
																	icon: Icons.check,
																	isSelected: true,
																	onTap: () {},
																	onMouseEnter: () {},
																	onMouseExit: () {},
																)
															else
																NavRectButton(
																	text: '选择',
																	icon: Icons.add,
																	isSelected: false,
																	onTap: () => _select(installation),
																	onMouseEnter: () {},
																	onMouseExit: () {},
																),
														],
													),
												);
											},
										),
							),
							const SizedBox(height: 12),
							Align(
								alignment: Alignment.centerRight,
								child: NavRectButton(
									text: '取消',
									icon: Icons.close,
									isSelected: false,
									defaultBorderColor: tokens.colorSecondary.withValues(
										alpha: 0.35,
									),
									onTap: () => Navigator.of(context).pop(),
									onMouseEnter: () {},
									onMouseExit: () {},
								),
							),
						],
					),
				),
			),
		);
	}
}
