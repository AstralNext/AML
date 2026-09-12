import 'dart:async';
import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/accounts/application/account_avatar_cache.dart';
import 'package:aml/src/features/wardrobe/application/skin_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

/// Circular account avatar: local skin **head** thumbnail when available.
class AccountAvatar extends StatefulWidget {
	final rust.AccountDto account;
	final double size;

	const AccountAvatar({
		super.key,
		required this.account,
		this.size = 32,
	});

	static String initialFor(String username) {
		final t = username.trim();
		if (t.isEmpty) return '?';
		return String.fromCharCode(t.runes.first).toUpperCase();
	}

	static Color accentFor(String username, ColorScheme scheme) {
		final hash = username.codeUnits.fold<int>(0, (a, b) => a + b);
		final hues = <Color>[
			scheme.primary,
			scheme.tertiary,
			scheme.secondary,
			const Color(0xFF3BA55D),
			const Color(0xFF5865F2),
			const Color(0xFFE67E22),
		];
		return hues[hash % hues.length];
	}

	@override
	State<AccountAvatar> createState() => _AccountAvatarState();
}

class _AccountAvatarState extends State<AccountAvatar> {
	AccountAvatarCache get _cache {
		if (!getIt.isRegistered<AccountAvatarCache>()) {
			getIt.registerSingleton<AccountAvatarCache>(AccountAvatarCache());
		}
		return getIt<AccountAvatarCache>();
	}

	Uint8List? _bytes;
	bool _resolving = false;
	bool _resolveAttempted = false;
	VoidCallback? _unsubscribe;

	@override
	void initState() {
		super.initState();
		_bytes = _cache.peek(widget.account.uuid);
		_resolveAttempted = _bytes != null;
		_unsubscribe = _cache.revision.subscribe((_) {
			if (!mounted) return;
			final next = _cache.peek(widget.account.uuid);
			if (next == _bytes) return;
			setState(() {
				_bytes = next;
				if (next != null) _resolveAttempted = true;
			});
		});
		unawaited(_warmIfNeeded());
	}

	@override
	void didUpdateWidget(covariant AccountAvatar oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.account.uuid != widget.account.uuid ||
			oldWidget.account.active != widget.account.active) {
			_bytes = _cache.peek(widget.account.uuid);
			_resolveAttempted = _bytes != null;
			unawaited(_warmIfNeeded());
		}
	}

	@override
	void dispose() {
		_unsubscribe?.call();
		super.dispose();
	}

	Future<void> _warmIfNeeded() async {
		// Disk/memory cache first — reopen should paint heads immediately.
		final cached = _cache.peek(widget.account.uuid);
		if (cached != null) {
			if (mounted && !identical(_bytes, cached)) {
				setState(() {
					_bytes = cached;
					_resolveAttempted = true;
				});
			} else {
				_bytes = cached;
				_resolveAttempted = true;
			}
			return;
		}
		if (_resolving) return;
		_resolving = true;
		try {
			// SkinStore holds skins for the currently active MSA/offline wardrobe.
			if (widget.account.active) {
				final skins = getIt<SkinStore>();
				await skins.ensureLoaded();
				await skins.warmAccountHead(widget.account.uuid);
			}
			final next = _cache.peek(widget.account.uuid);
			if (mounted) {
				setState(() {
					_bytes = next;
					_resolveAttempted = true;
				});
			}
		} catch (_) {
			if (mounted) {
				setState(() => _resolveAttempted = true);
			}
		} finally {
			_resolving = false;
		}
	}

	Widget _initials(BuildContext context) {
		final initial = AccountAvatar.initialFor(widget.account.username);
		final fallbackBg = AccountAvatar.accentFor(
			widget.account.username,
			Theme.of(context).colorScheme,
		);
		return Container(
			width: widget.size,
			height: widget.size,
			alignment: Alignment.center,
			decoration: BoxDecoration(
				color: fallbackBg.withValues(alpha: 0.85),
				shape: BoxShape.circle,
			),
			child: Text(
				initial,
				style: TextStyle(
					color: Colors.white,
					fontWeight: FontWeight.w800,
					fontSize: widget.size * 0.42,
					height: 1,
				),
			),
		);
	}

	@override
	Widget build(BuildContext context) {
		final tokens = context.tokens;
		final bytes = _bytes;

		if (bytes != null) {
			return ClipOval(
				child: Image.memory(
					bytes,
					width: widget.size,
					height: widget.size,
					fit: BoxFit.cover,
					gaplessPlayback: true,
					filterQuality: FilterQuality.none,
				),
			);
		}

		if (!_resolveAttempted && widget.account.active) {
			return ClipOval(
				child: Container(
					width: widget.size,
					height: widget.size,
					color: tokens.colorSuperRaisedBg,
					alignment: Alignment.center,
					child: SizedBox(
						width: widget.size * 0.35,
						height: widget.size * 0.35,
						child: CircularProgressIndicator(
							strokeWidth: 2,
							color: tokens.colorBrand,
						),
					),
				),
			);
		}

		return _initials(context);
	}
}
