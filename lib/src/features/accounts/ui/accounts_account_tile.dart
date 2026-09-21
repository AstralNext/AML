import 'package:aml/src/features/accounts/ui/account_avatar.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

class AccountTile extends StatefulWidget {
  final rust.AccountDto account;
  final String? serviceName;
  final bool canRemove;
  final VoidCallback onSelect;
  final VoidCallback? onEdit;
  final VoidCallback onRemove;

  const AccountTile({
    super.key,
    required this.account,
    this.serviceName,
    required this.canRemove,
    required this.onSelect,
    this.onEdit,
    required this.onRemove,
  });

  @override
  State<AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<AccountTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final a = widget.account;
    final selected = a.active;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: selected
              ? tokens.colorBrandHighlight
              : _hovered
                  ? tokens.colorSuperRaisedBg
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onSelect,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                    color: selected
                        ? tokens.colorBrand
                        : tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 10),
                  AccountAvatar(account: a, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tokens.colorContrast,
                          ),
                        ),
                        Text(
                          switch (a.kind) {
                            'msa' => '微软账号',
                            'yggdrasil' =>
                              '${widget.serviceName ?? '外置登录'} · 外置账号',
                            _ => '离线账号',
                          },
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.colorBase.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onEdit != null)
                    IconButton(
                      tooltip: '修改皮肤',
                      onPressed: widget.onEdit,
                      icon: Icon(
                        Icons.edit_outlined,
                        color: tokens.colorBrand,
                      ),
                    ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: widget.canRemove ? widget.onRemove : null,
                    icon: Icon(
                      Icons.delete_outline,
                      color: widget.canRemove
                          ? tokens.colorBase.withValues(alpha: 0.75)
                          : tokens.colorBase.withValues(alpha: 0.25),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
