import 'dart:async';

import 'package:aml/src/features/java/application/java_download_service.dart';
import 'package:aml/src/features/settings/domain/models/java_settings.dart';
import 'package:aml/src/features/settings/ui/widgets/java_detection_dialog.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

class JavaSelector extends StatefulWidget {
	const JavaSelector({
		super.key,
		required this.version,
		required this.path,
		required this.onPathChanged,
		required this.javaDownloadService,
		this.appDataDir,
		this.disabled = false,
	});

	final int version;
	final String path;
	final ValueChanged<String> onPathChanged;
	final JavaDownloadService javaDownloadService;
	final String? appDataDir;
	final bool disabled;

	@override
	State<JavaSelector> createState() => _JavaSelectorState();
}

class _JavaSelectorState extends State<JavaSelector> {
	late final TextEditingController _controller;
	bool _testing = false;
	bool? _testSuccess;
	bool _installing = false;
	bool _hoveringTest = false;
	bool _initialized = false;
	Timer? _debounceTimer;

	@override
	void initState() {
		super.initState();
		_controller = TextEditingController(text: widget.path);
		if (widget.path.isNotEmpty) {
			_runTest(widget.path, track: false);
			_initialized = true;
		}
	}

	@override
	void didUpdateWidget(JavaSelector oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.path != widget.path && _controller.text != widget.path) {
			_controller.text = widget.path;
			if (widget.path.isEmpty) {
				setState(() => _testSuccess = null);
			} else if (!_initialized) {
				_runTest(widget.path, track: false);
				_initialized = true;
			} else {
				_scheduleDebouncedTest(widget.path);
			}
		}
	}

	@override
	void dispose() {
		_debounceTimer?.cancel();
		_controller.dispose();
		super.dispose();
	}

	void _scheduleDebouncedTest(String path) {
		_debounceTimer?.cancel();
		if (path.isEmpty) {
			setState(() => _testSuccess = null);
			return;
		}
		_debounceTimer = Timer(const Duration(milliseconds: 600), () {
			_runTest(path, track: false);
		});
	}

	Future<void> _runTest(String path, {required bool track}) async {
		if (path.isEmpty) {
			setState(() => _testSuccess = null);
			return;
		}

		setState(() => _testing = true);
		final success = await widget.javaDownloadService.testJRE(
			path,
			widget.version,
		);
		if (!mounted) return;
		setState(() {
			_testing = false;
			_testSuccess = success;
		});
	}

	void _updatePath(String path) {
		final canonical = JavaSettings.canonicalizeExecutablePath(path);
		widget.onPathChanged(canonical);
		if (_controller.text != canonical) {
			_controller.text = canonical;
		}
		_scheduleDebouncedTest(canonical);
	}

	Future<void> _installRecommended() async {
		if (widget.disabled || _installing) return;

		setState(() => _installing = true);
		try {
			final result = await widget.javaDownloadService.autoInstallJava(
				widget.version,
			);
			if (result != null && result.isNotEmpty) {
				_updatePath(result);
				await _runTest(result, track: true);
			}
		} finally {
			if (mounted) {
				setState(() => _installing = false);
			}
		}
	}

	Future<void> _browse() async {
		if (widget.disabled) return;

		try {
			final result = await FilePicker.platform.pickFiles(
				type: FileType.any,
				allowMultiple: false,
			);
			final pickedPath = result?.files.single.path;
			if (pickedPath == null || pickedPath.isEmpty) return;

			final checked = await widget.javaDownloadService.checkJRE(pickedPath);
			if (checked != null) {
				_updatePath(checked.path);
			} else {
				_updatePath(pickedPath);
			}
		} catch (_) {}
	}

	Future<void> _detect() async {
		if (widget.disabled) return;

		final selected = await JavaDetectionDialog.show(
			context,
			version: widget.version,
			currentPath: widget.path,
			javaDownloadService: widget.javaDownloadService,
			appDataDir: widget.appDataDir,
		);
		if (selected != null) {
			_updatePath(selected.path);
			await _runTest(selected.path, track: true);
		}
	}

	Color _testButtonColor(BuildContext context) {
		final tokens = context.tokens;
		if (_hoveringTest || _testing || widget.disabled) {
			return tokens.colorSecondary.withValues(alpha: 0.2);
		}
		if (_testSuccess == true) {
			return Colors.green.withValues(alpha: 0.2);
		}
		return Colors.red.withValues(alpha: 0.2);
	}

	Color _testIconColor(BuildContext context) {
		final tokens = context.tokens;
		if (_hoveringTest || _testing || widget.disabled) {
			return tokens.colorContrast;
		}
		if (_testSuccess == true) {
			return Colors.green;
		}
		return Colors.red;
	}

	IconData _testIcon() {
		if (_testing) return Icons.autorenew;
		if (_hoveringTest || widget.disabled) return Icons.refresh;
		if (_testSuccess == true) return Icons.check_circle_outline;
		return Icons.cancel_outlined;
	}

	@override
	Widget build(BuildContext context) {
		final colorScheme = Theme.of(context).colorScheme;
		final tokens = context.tokens;
		final alreadyInstalled = _testSuccess == true;

		return Column(
			crossAxisAlignment: CrossAxisAlignment.start,
			children: [
				Row(
					children: [
						Expanded(
							child: InputBarWidget(
								colorScheme: colorScheme,
								size: InputBarSize.medium,
								hintText: '/path/to/java',
								controller: _controller,
								onChanged: _updatePath,
							),
						),
						const SizedBox(width: 8),
						MouseRegion(
							onEnter: widget.disabled
								? null
								: (_) => setState(() => _hoveringTest = true),
							onExit: widget.disabled
								? null
								: (_) => setState(() => _hoveringTest = false),
							child: Material(
								color: _testButtonColor(context),
								borderRadius: BorderRadius.circular(8),
								child: InkWell(
									borderRadius: BorderRadius.circular(8),
									onTap: widget.disabled || _testing
										? null
										: () => _runTest(widget.path, track: true),
									child: SizedBox(
										width: 40,
										height: 40,
										child: Center(
											child: _testing
												? SizedBox(
													width: 18,
													height: 18,
													child: CircularProgressIndicator(
														strokeWidth: 2,
														color: tokens.colorContrast,
													),
												)
												: Icon(
													_testIcon(),
													size: 20,
													color: _testIconColor(context),
												),
										),
									),
								),
							),
						),
					],
				),
				const SizedBox(height: 8),
				Wrap(
					spacing: 8,
					runSpacing: 8,
					children: [
						NavRectButton(
							text: _installing ? '安装中...' : '安装推荐版本',
							icon: Icons.download_outlined,
							isSelected: false,
							label: alreadyInstalled ? '已安装' : null,
							onTap: widget.disabled || _installing || alreadyInstalled
								? () {}
								: _installRecommended,
							onMouseEnter: () {},
							onMouseExit: () {},
						),
						NavRectButton(
							text: '检测',
							icon: Icons.search,
							isSelected: false,
							onTap: widget.disabled ? () {} : _detect,
							onMouseEnter: () {},
							onMouseExit: () {},
						),
						NavRectButton(
							text: '浏览',
							icon: Icons.folder_open,
							isSelected: false,
							onTap: widget.disabled ? () {} : _browse,
							onMouseEnter: () {},
							onMouseExit: () {},
						),
					],
				),
			],
		);
	}
}
