import 'package:flutter/foundation.dart';

import 'package:aml/src/features/discover/domain/discover_repository.dart';

class DiscoverController {
  final DiscoverRepository repository;

  final ValueNotifier<bool> loading = ValueNotifier(false);
  final ValueNotifier<String?> error = ValueNotifier(null);
  final ValueNotifier<List<Project>> projects = ValueNotifier(const []);
  final ValueNotifier<int> totalHits = ValueNotifier(0);
  final ValueNotifier<int> page = ValueNotifier(0);

  int _searchSerial = 0;

  DiscoverController(this.repository);

  Future<void> search(
    String query, {
    int pageIndex = 0,
    int pageSize = 20,
    String? index,
    List<List<String>>? facets,
  }) async {
    final serial = ++_searchSerial;
    loading.value = true;
    error.value = null;
    // When MCDB shards are warm, onLocalized can run (microtask) before this
    // await resumes — never let the provisional English payload overwrite it.
    var localizedApplied = false;
    try {
      final results = await repository.searchProjects(
        query: query,
        page: pageIndex,
        pageSize: pageSize,
        index: index,
        facets: facets,
        onLocalized: (localized) {
          if (serial != _searchSerial) return;
          localizedApplied = true;
          projects.value = localized.projects;
          totalHits.value = localized.totalHits;
        },
      );
      if (serial != _searchSerial) return;
      if (!localizedApplied) {
        projects.value = results.projects;
        totalHits.value = results.totalHits;
      }
      page.value = pageIndex;
    } catch (e) {
      if (serial != _searchSerial) return;
      error.value = e.toString();
    } finally {
      if (serial == _searchSerial) {
        loading.value = false;
      }
    }
  }
}
