import 'dart:math';

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'models.dart';
import 'remote_widgets.dart';

class CatalogFilters extends StatefulWidget {
  const CatalogFilters({
    super.key,
    required this.categories,
    required this.category,
    required this.onCategory,
    required this.onRetry,
    this.error,
    this.trailing,
    this.filters = const [],
    this.filterValues = const {},
    this.onFilters,
  });

  final List<CatalogCategory> categories;
  final String category;
  final String? error;
  final ValueChanged<String> onCategory;
  final VoidCallback onRetry;
  final Widget? trailing;
  final List<PythonCatalogFilter> filters;
  final Map<String, String> filterValues;
  final ValueChanged<Map<String, String>>? onFilters;

  @override
  State<CatalogFilters> createState() => _CatalogFiltersState();
}

class _CatalogFiltersState extends State<CatalogFilters> {
  final _anchors = <String, GlobalKey>{};

  Future<void> _selectFilters() async {
    final values = Map<String, String>.from(widget.filterValues);
    for (final filter in widget.filters) {
      if (filter.values.isNotEmpty) {
        values.putIfAbsent(
          filter.key,
          () => filter.values.containsKey(filter.initial)
              ? filter.initial
              : filter.values.keys.first,
        );
      }
    }
    final selected = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final filter in widget.filters)
                          if (filter.key.isNotEmpty && filter.values.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: DropdownButtonFormField<String>(
                                initialValue:
                                    filter.values.containsKey(
                                      values[filter.key] ?? filter.initial,
                                    )
                                    ? values[filter.key] ?? filter.initial
                                    : filter.values.keys.first,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: filter.name,
                                ),
                                items: [
                                  for (final value in filter.values.entries)
                                    DropdownMenuItem(
                                      value: value.key,
                                      child: Text(value.value),
                                    ),
                                ],
                                onChanged: (value) => update(() {
                                  if (value != null) values[filter.key] = value;
                                }),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () =>
                          Navigator.pop(context, <String, String>{}),
                      child: const Text('重置'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, values),
                      child: const Text('应用筛选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) widget.onFilters?.call(selected);
  }

  @override
  void didUpdateWidget(covariant CatalogFilters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final anchor = _anchors[widget.category]?.currentContext;
        if (mounted && anchor != null) {
          Scrollable.ensureVisible(
            anchor,
            alignment: .4,
            duration: const Duration(milliseconds: 180),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: television
          ? 64
          : max(58, MediaQuery.textScalerOf(context).scale(14) + 32),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey('catalog-categories'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  for (final entry in widget.categories)
                    Padding(
                      key: _anchors.putIfAbsent(entry.id, GlobalKey.new),
                      padding: const EdgeInsets.only(right: 8),
                      child: television
                          ? RemoteButton(
                              key: ValueKey('category-${entry.id}'),
                              label: entry.name,
                              selected: entry.id == widget.category,
                              onPressed: () => widget.onCategory(entry.id),
                            )
                          : ChoiceChip(
                              key: ValueKey('category-${entry.id}'),
                              label: Text(entry.name),
                              selected: entry.id == widget.category,
                              showCheckmark: false,
                              backgroundColor: Colors.transparent,
                              selectedColor: colors.primary.withValues(
                                alpha: .12,
                              ),
                              labelStyle: TextStyle(
                                color: entry.id == widget.category
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                                fontSize: 14,
                                fontWeight: entry.id == widget.category
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                              onSelected: (_) => widget.onCategory(entry.id),
                            ),
                    ),
                ],
              ),
            ),
          ),
          if (widget.error != null)
            IconButton(
              tooltip: widget.error,
              onPressed: widget.onRetry,
              icon: Icon(
                Icons.refresh_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (widget.filters.isNotEmpty && widget.onFilters != null)
            IconButton(
              tooltip: '筛选',
              onPressed: _selectFilters,
              icon: Icon(
                widget.filterValues.isEmpty
                    ? Icons.filter_alt_outlined
                    : Icons.filter_alt,
              ),
            ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }
}
